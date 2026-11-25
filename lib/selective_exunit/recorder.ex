defmodule SelectiveExunit.Recorder do
  alias SelectiveExunit.JSON
  alias SelectiveExunit.State

  def available? do
    Code.ensure_loaded?(:cover) and Process.whereis(:cover_server) == nil
  end

  def start(prefix, compile_path \\ Mix.Project.compile_path()) do
    with {:ok, server} <- :cover.start(),
         results when is_list(results) <-
           :cover.compile_beam_directory(to_charlist(compile_path)),
         [] <- for({:error, reason} <- results, do: reason) do
      sources =
        for {:ok, module} <- results, path <- List.wrap(source(module, prefix)), into: %{} do
          {module, path}
        end

      ignore =
        System.get_env("SELECTIVE_TEST_MAP_IGNORE", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      {native, fallback} = sources |> Map.keys() |> Enum.split_with(&native?/1)

      State.put(:recording, %{
        server: server,
        prefix: prefix,
        sources: sources,
        native: native,
        fallback: fallback,
        ignore: ignore,
        deps: %{}
      })
    else
      {:error, reason} -> {:error, reason}
      failed -> {:error, {:not_cover_compiled, failed}}
    end
  end

  def reset do
    case State.get(:recording) do
      nil ->
        :ok

      %{native: native, fallback: fallback} ->
        Enum.each(native, &reset_native/1)
        Enum.each(fallback, &:cover.reset/1)
    end
  end

  def collect(test_case, tests) do
    case State.get(:recording) do
      nil ->
        :ok

      %{server: server} = recording ->
        cond do
          Process.whereis(:cover_server) != server ->
            State.put(:recording, nil)

            IO.puts(
              :stderr,
              "Selective stopped test map recording (:cover stopped during #{test_case.id}); tests run normally and this runner uploads no test map"
            )

          Enum.any?(tests, &ran?/1) ->
            record(recording, test_case)

          true ->
            :ok
        end
    end
  end

  defp record(%{prefix: prefix, sources: sources, ignore: ignore} = recording, test_case) do
    called =
      Enum.filter(recording.native, &native_called?/1) ++
        Enum.filter(recording.fallback, &cover_called?/1)

    files =
      [prefix <> test_case.file_path | Enum.map(called, &sources[&1])]
      |> Enum.reject(fn file -> Enum.any?(ignore, &String.starts_with?(file, &1)) end)
      |> MapSet.new()

    State.update(
      :recording,
      &update_in(&1.deps[test_case.id], fn old -> MapSet.union(old || MapSet.new(), files) end)
    )
  end

  def upload(env, transport) do
    case State.get(:recording) do
      %{deps: deps} when map_size(deps) > 0 -> post(fragment(deps), env, transport)
      _ -> :ok
    end
  end

  defp post(fragment, env, transport) do
    path =
      Path.join(
        System.tmp_dir!(),
        "selective-exunit-fragment-#{System.unique_integer([:positive])}"
      )

    File.write!(path, :zlib.gzip(JSON.encode(fragment)))

    {output, _status} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          ~s(exec "$0" --upload-fragment --run-id "$1" --run-attempt "$2" --runner-id "$3" < "$4"),
          transport,
          env.run_id,
          env.run_attempt,
          env.runner_id,
          path
        ],
        env: [{"SELECTIVE_TEST_MAP_UPLOAD_KEY", env.api_key}],
        stderr_to_stdout: true
      )

    File.rm!(path)
    IO.write(:stderr, output)
  end

  defp fragment(deps) do
    files = deps |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2) |> Enum.sort()
    index = files |> Enum.with_index() |> Map.new()

    tests =
      for {id, paths} <- deps,
          do: %{"id" => id, "deps" => paths |> Enum.map(&index[&1]) |> Enum.sort()}

    %{"version" => 1, "files" => files, "tests" => tests}
  end

  defp native?(module) do
    :code.coverage_support() and
      try do
        :code.get_coverage(:line, module)
        true
      rescue
        ArgumentError -> false
      end
  end

  defp reset_native(module) do
    :code.reset_coverage(module)
  rescue
    ArgumentError -> :cover.reset(module)
  end

  defp native_called?(module) do
    Enum.any?(:code.get_coverage(:line, module), fn {_line, count} -> count > 0 end)
  rescue
    ArgumentError -> cover_called?(module)
  end

  defp cover_called?(module) do
    called =
      case :cover.analyse(module, :calls, :module) do
        {:ok, {^module, count}} -> count > 0
        {:error, _} -> false
      end

    :cover.reset(module)
    called
  end

  defp source(module, prefix) do
    root = Path.expand(String.replace_suffix(File.cwd!() <> "/", prefix, ""))
    file = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(root)

    if Path.type(file) == :relative, do: file
  end

  defp ran?(%{state: {state, _}}) when state in [:skipped, :excluded], do: false
  defp ran?(_test), do: true
end
