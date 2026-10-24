defmodule SelectiveExunit.Options do
  @applied [
    include: :keep,
    exclude: :keep,
    only: :keep,
    name_pattern: :keep,
    failed: :boolean,
    seed: :integer,
    timeout: :integer,
    trace: :boolean,
    exit_status: :integer,
    color: :boolean,
    formatter: :keep,
    slowest: :integer,
    slowest_modules: :integer,
    warnings_as_errors: :boolean,
    compile: :boolean,
    start: :boolean,
    deps_check: :boolean,
    archives_check: :boolean,
    elixir_version_check: :boolean,
    force: :boolean,
    all_warnings: :boolean,
    debug: :boolean
  ]

  @rejected [
    cover: :boolean,
    export_coverage: :string,
    stale: :boolean,
    partitions: :integer,
    max_cases: :integer,
    max_failures: :integer,
    repeat_until_failure: :integer,
    breakpoints: :boolean,
    listen_on_stdin: :boolean,
    dry_run: :boolean,
    raise: :boolean,
    preload_modules: :boolean,
    max_requires: :integer,
    profile_require: :string
  ]

  @aliases [b: :breakpoints, n: :name_pattern]

  def parse(args) do
    case OptionParser.parse(args, strict: @applied ++ @rejected, aliases: @aliases) do
      {opts, files, []} -> check(normalize(opts), files)
      {_opts, _files, [{flag, _} | _]} -> {:error, "mix selective.test does not know #{flag}"}
    end
  end

  def location_config(files) when is_list(files) do
    ExUnit.Filters.parse_paths(files)
  end

  def ex_unit_config(opts) do
    selection = parse_filters(opts, :only) ++ Keyword.get_values(opts, :name_pattern)

    config =
      []
      |> maybe_put(:include, filters_or_nil(opts, :include))
      |> maybe_put(:exclude, filters_or_nil(opts, :exclude))
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:timeout, opts[:timeout])
      |> maybe_put(:trace, opts[:trace])
      |> maybe_put(:exit_status, opts[:exit_status])
      |> maybe_put(:slowest, opts[:slowest])
      |> maybe_put(:slowest_modules, opts[:slowest_modules])
      |> maybe_put(:colors, if(Keyword.has_key?(opts, :color), do: [enabled: opts[:color]]))
      |> maybe_put(:formatters, formatters(opts))

    config =
      if selection == [] do
        config
      else
        config
        |> Keyword.update(:include, selection, &(selection ++ &1))
        |> Keyword.update(:exclude, [:test], &[:test | &1])
      end

    [autorun: false, max_cases: 1, capture_log: true] ++ config
  end

  defp check(opts, files) do
    case Enum.find(Keyword.keys(opts), &Keyword.has_key?(@rejected, &1)) do
      nil -> compile_patterns(opts, files)
      key -> {:error, "mix selective.test does not support --#{dasherize(key)}"}
    end
  end

  defp compile_patterns(opts, files) do
    patterns = Keyword.get_values(opts, :name_pattern)

    cond do
      patterns == [] ->
        {opts, files}

      Version.match?(System.version(), "< 1.19.0") ->
        {:error, "--name-pattern needs Elixir 1.19 or later, as in mix test"}

      true ->
        with {:ok, regexes} <- compile_all(patterns) do
          tests = Enum.map(regexes, &{:name_pattern, {:test, &1}})
          {Keyword.delete(opts, :name_pattern) ++ tests, files}
        end
    end
  end

  defp compile_all(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case Regex.compile(pattern) do
        {:ok, regex} ->
          {:cont, {:ok, acc ++ [regex]}}

        {:error, _} ->
          {:halt, {:error, "--name-pattern #{inspect(pattern)} is not a valid regex"}}
      end
    end)
  end

  defp normalize(opts) do
    Keyword.put_new(opts, :debug, System.get_env("SELECTIVE_DEBUG") in ["1", "true"])
  end

  defp formatters(opts) do
    case Keyword.get_values(opts, :formatter) do
      [] -> nil
      names -> Enum.map(names, &Module.concat([&1]))
    end
  end

  defp parse_filters(opts, key) do
    opts |> Keyword.get_values(key) |> Enum.map(&to_string/1) |> ExUnit.Filters.parse()
  end

  defp filters_or_nil(opts, key) do
    if Keyword.has_key?(opts, key), do: parse_filters(opts, key)
  end

  defp dasherize(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)
end
