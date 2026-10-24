defmodule SelectiveExunit.Recorder do
  alias SelectiveExunit.JSON
  alias SelectiveExunit.State

  def available? do
    Code.ensure_loaded?(:cover) and Process.whereis(:cover_server) == nil
  end

  def start(prefix) do
    with {:ok, server} <- :cover.start(),
         results when is_list(results) <-
           :cover.compile_beam_directory(to_charlist(Mix.Project.compile_path())),
         [] <- for({:error, reason} <- results, do: reason) do
      sources =
        for {:ok, module} <- results, path <- List.wrap(source(module, prefix)), into: %{} do
          {module, path}
        end

      ignore =
        System.get_env("SELECTIVE_TEST_MAP_IGNORE", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      State.put(:recording, %{
        server: server,
        prefix: prefix,
        sources: sources,
        ignore: ignore,
        deps: %{}
      })
    else
      {:error, reason} -> {:error, reason}
      failed -> {:error, {:not_cover_compiled, failed}}
    end
  end

  def reset do
    if State.get(:recording), do: :ok = :cover.reset()
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

  defp record(%{prefix: prefix, sources: sources, ignore: ignore}, test_case) do
    {:result, calls, _} = :cover.analyse(:calls, :module)

    files =
      for {module, count} <- calls,
          count > 0,
          Map.has_key?(sources, module),
          do: sources[module]

    files =
      [prefix <> test_case.file_path | files]
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

  defp source(module, prefix) do
    root = Path.expand(String.replace_suffix(File.cwd!() <> "/", prefix, ""))
    file = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(root)

    if Path.type(file) == :relative, do: file
  end

  defp ran?(%{state: {state, _}}) when state in [:skipped, :excluded], do: false
  defp ran?(_test), do: true
end
