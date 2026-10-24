defmodule SelectiveExunit.Env do
  @required [
    {"api_key", "SELECTIVE_API_KEY"},
    {"host", "SELECTIVE_HOST"},
    {"platform", "SELECTIVE_PLATFORM"},
    {"run_id", "SELECTIVE_RUN_ID"},
    {"run_attempt", "SELECTIVE_RUN_ATTEMPT"},
    {"branch", "SELECTIVE_BRANCH"},
    {"sha", "SELECTIVE_SHA"},
    {"git_repo_full_name", "SELECTIVE_GIT_REPO"},
    {"git_provider", "SELECTIVE_GIT_PROVIDER"}
  ]

  @metadata ~w(platform branch pr_title target_branch actor sha base_sha commit_message committer_name committer_email git_repo_full_name git_provider)

  @ci_markers ["GITHUB_ACTIONS", "CIRCLECI", "SEMAPHORE", "BUILDKITE", "RWX", "MINT"]

  def wants_connection? do
    present?("SELECTIVE_API_KEY") or present?("SELECTIVE_HOST") or
      Enum.any?(@ci_markers, &present?/1)
  end

  def resolve(binary) do
    case System.cmd(binary, ["--build-env"]) do
      {output, 0} -> output |> String.trim() |> decode() |> build()
      {_output, status} -> {:error, "transport --build-env exited #{status}"}
    end
  end

  def websocket_url(env, reconnect) do
    host = String.trim_trailing(env.host, "/")

    pairs =
      [
        {"api_key", env.api_key},
        {"run_id", env.run_id},
        {"run_attempt", env.run_attempt},
        {"runner_id", env.runner_id},
        {"language", "elixir"},
        {"core_version", SelectiveExunit.version()},
        {"framework", "exunit"},
        {"framework_version", System.version()},
        {"framework_wrapper_version", SelectiveExunit.version()},
        {"runtime_version", System.version()},
        {"test_map", env.test_map},
        {"test_map_record", env.test_map_record},
        {"remove_failed", "true"},
        {"metadata", SelectiveExunit.JSON.encode(env.metadata)}
      ] ++ if(reconnect, do: [{"reconnect", "true"}], else: [])

    host <> "/transport/websocket?" <> URI.encode_query(pairs)
  end

  def test_map do
    cond do
      String.downcase(System.get_env("SELECTIVE_TEST_MAP_DISABLE", "")) in ["1", "true", "yes"] ->
        "0"

      SelectiveExunit.Recorder.available?() ->
        "record"

      true ->
        "select"
    end
  end

  def test_map_record do
    System.get_env("SELECTIVE_TEST_MAP_RECORD") || ""
  end

  defp decode(output) do
    {:ok, SelectiveExunit.JSON.decode(output)}
  rescue
    error in ErlangError ->
      {:error, "transport --build-env printed invalid JSON (#{Exception.message(error)})"}
  end

  defp build({:error, message}), do: {:error, message}

  defp build({:ok, decoded}) do
    missing = for {key, name} <- @required, field(decoded, key) == "", do: name
    host = field(decoded, "host")

    cond do
      missing != [] ->
        {:error, "missing #{Enum.join(missing, ", ")}"}

      not String.match?(host, ~r{^wss?://}) ->
        {:error, "SELECTIVE_HOST must start with ws:// or wss://, got #{inspect(host)}"}

      true ->
        metadata = Map.new(@metadata, &{&1, field(decoded, &1)})

        {:ok,
         %{
           api_key: field(decoded, "api_key"),
           host: host,
           run_id: field(decoded, "run_id"),
           run_attempt: field(decoded, "run_attempt"),
           runner_id: runner_id(field(decoded, "runner_id")),
           target_branch: metadata["target_branch"],
           test_map: test_map(),
           test_map_record: test_map_record(),
           metadata: metadata
         }}
    end
  end

  defp field(decoded, key) do
    case Map.get(decoded, key) do
      nil -> ""
      :null -> ""
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp runner_id(""), do: "selgen-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp runner_id(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 80)
  end

  defp present?(key), do: System.get_env(key) not in [nil, ""]
end
