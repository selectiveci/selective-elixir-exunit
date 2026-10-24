defmodule SelectiveExunit.Discovery do
  alias SelectiveExunit.Ids
  alias SelectiveExunit.Options
  alias SelectiveExunit.UTF8

  def test_alias do
    steps = List.wrap(Mix.Project.config()[:aliases][:test])

    case Enum.split_while(steps, &(not test_step?(&1))) do
      {before, []} ->
        %{before: before, args: [], after: []}

      {before, [test | rest]} ->
        %{before: before, args: tl(OptionParser.split(test)), after: rest}
    end
  end

  def run_step(step) when is_function(step, 1), do: step.([])

  def run_step(step) do
    [task | args] = OptionParser.split(step)
    Mix.Task.run(task, args)
  end

  defp test_step?(step), do: is_binary(step) and hd(OptionParser.split(step)) == "test"

  def load(opts, files, args) do
    Mix.Task.run("compile", args -- ["--warnings-as-errors"])
    Mix.Task.run("app.start", args)

    config = Options.ex_unit_config(opts)
    ExUnit.configure(config)

    project = Mix.Project.config()
    test_paths = project[:test_paths] || ["test"]
    Enum.each(test_paths, &require_test_helper/1)

    unless Process.whereis(ExUnit.Server) do
      ExUnit.start(autorun: false)
    end

    ExUnit.configure(merge_helper_excludes(config))

    {paths, location_opts} =
      if files == [] do
        {test_paths, []}
      else
        Options.location_config(files)
      end

    merge_location(location_opts)

    failed = failed_filter(opts)
    load_paths = collect_files(paths, project)

    load_paths =
      case failed do
        {:subset, allowed, _ids} ->
          Enum.filter(load_paths, &MapSet.member?(allowed, Path.expand(&1)))

        _ ->
          load_paths
      end

    with {:ok, modules} <- require_test_files(load_paths, project, opts) do
      cases =
        modules
        |> Enum.filter(&function_exported?(&1, :__ex_unit__, 0))
        |> Enum.flat_map(&cases_for(&1, failed))
        |> Enum.map(fn test_case ->
          {Ids.wire_id(test_case.module, test_case.name), test_case}
        end)
        |> Ids.disambiguate()
        |> Enum.map(fn {id, test_case} -> %{test_case | id: id} end)

      if cases == [] do
        {:error, empty_reason(files, opts)}
      else
        {:ok, cases}
      end
    end
  end

  defp require_test_helper(test_path) do
    helper = Path.join(test_path, "test_helper.exs")

    if File.regular?(helper) do
      Code.require_file(helper)
    end

    :ok
  end

  defp merge_location([]), do: :ok

  defp merge_location(opts) do
    include = Keyword.get(opts, :include, []) ++ Application.get_env(:ex_unit, :include, [])
    exclude = Keyword.get(opts, :exclude, []) ++ Application.get_env(:ex_unit, :exclude, [])
    ExUnit.configure(include: include, exclude: Enum.uniq(exclude))
  end

  defp merge_helper_excludes(config) do
    helper = List.wrap(Application.get_env(:ex_unit, :exclude, []))
    Keyword.update(config, :exclude, helper, &Enum.uniq(&1 ++ helper))
  end

  defp failed_filter(opts) do
    if opts[:failed] do
      manifest = Path.join(Mix.Project.manifest_path(), ".mix_test_failures")

      case ExUnit.Filters.failure_info(manifest) do
        :all -> :all
        {files, ids} -> {:subset, files, ids}
      end
    end
  end

  defp collect_files(paths, project) do
    pattern = project[:test_pattern] || "*_test.exs"

    paths
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) ->
          Path.wildcard(Path.join([path, "**", pattern]))

        File.regular?(path) ->
          [path]

        true ->
          []
      end
    end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&loadable?/1)
  end

  defp loadable?(path) do
    String.ends_with?(path, ".exs") and not String.ends_with?(path, "_helper.exs")
  end

  defp require_test_files([], _project, _opts), do: {:ok, []}

  defp require_test_files(files, project, opts) do
    previous = Code.compiler_options(project[:test_elixirc_options] || [])

    try do
      case Kernel.ParallelCompiler.require(files, return_diagnostics: true) do
        {:ok, modules, warnings} ->
          if opts[:warnings_as_errors] && warned?(warnings) do
            {:error, "test files compiled with warnings and --warnings-as-errors is set"}
          else
            {:ok, modules}
          end

        {:error, errors, _warnings} ->
          {:error, format_errors(errors)}
      end
    after
      Code.compiler_options(previous)
    end
  end

  defp warned?(%{compile_warnings: compile, runtime_warnings: runtime}),
    do: compile != [] or runtime != []

  defp cases_for(module, failed) do
    test_module = module.__ex_unit__()
    tests = test_module.tests
    include = Application.get_env(:ex_unit, :include, [])
    exclude = Application.get_env(:ex_unit, :exclude, [])
    {include, exclude} = ExUnit.Filters.normalize(include, exclude)

    tests
    |> Enum.filter(&keep?(&1, tests, include, exclude, failed))
    |> Enum.map(&to_case/1)
  end

  defp keep?(test, tests, include, exclude, failed) do
    tags =
      test.tags
      |> Map.merge(%{test: test.name, module: test.module})
      |> Map.merge(filter_tags(test.module))

    included =
      case ExUnit.Filters.eval(include, exclude, tags, tests) do
        {:excluded, _} -> false
        _ -> true
      end

    included and failed_allows?(test, failed)
  end

  defp filter_tags(module) do
    if function_exported?(module, :__ex_unit__, 1) do
      config = module.__ex_unit__(:config)
      %{async: config.async?, test_group: Map.get(config, :group)}
    else
      %{}
    end
  end

  defp failed_allows?(_test, nil), do: true
  defp failed_allows?(_test, :all), do: true

  defp failed_allows?(test, {:subset, _files, ids}) do
    MapSet.member?(ids, {test.module, test.name})
  end

  defp to_case(test) do
    description =
      test.name
      |> Atom.to_string()
      |> String.replace_prefix("test ", "")
      |> String.replace_prefix("#{test.tags[:describe]} ", "")

    file = Path.relative_to(to_string(test.tags[:file] || ""), File.cwd!())

    %{
      id: nil,
      module: test.module,
      name: test.name,
      file_path: UTF8.scrub(file),
      line_number: test.tags[:line] || 0,
      description: UTF8.scrub(description),
      full_description:
        UTF8.scrub(
          [inspect(test.module), test.tags[:describe], description]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
        )
    }
  end

  defp empty_reason([], opts) do
    if opts[:failed] do
      "no failed tests were found"
    else
      "the suite did not register any tests"
    end
  end

  defp empty_reason(files, _opts) do
    "no tests matched #{Enum.join(files, ", ")}"
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "\n", &"#{&1.file}:#{inspect(&1.position)}: #{&1.message}")
  end
end
