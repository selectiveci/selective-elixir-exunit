defmodule SelectiveExunit.EnvTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Env

  @ci ["GITHUB_ACTIONS", "CIRCLECI", "SEMAPHORE", "BUILDKITE", "RWX", "MINT"]

  setup do
    saved = Map.new(@ci, &{&1, System.get_env(&1)})
    Enum.each(@ci, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "advertises record while cover is free, select while it is taken, 0 when disabled" do
    System.delete_env("SELECTIVE_TEST_MAP_DISABLE")
    assert Env.test_map() == "record"
    {:ok, _pid} = :cover.start()
    assert Env.test_map() == "select"
    :ok = :cover.stop()
    System.put_env("SELECTIVE_TEST_MAP_DISABLE", "YES")
    assert Env.test_map() == "0"
    System.delete_env("SELECTIVE_TEST_MAP_DISABLE")
  end

  test "puts the identity query on the websocket url" do
    env = %{
      host: "ws://127.0.0.1:9",
      api_key: "k",
      run_id: "run",
      run_attempt: "2",
      runner_id: "runner",
      test_map: "select",
      test_map_record: "",
      metadata: %{"branch" => "main"}
    }

    assert Env.websocket_url(env, false) =~ "&remove_failed=true&"
    url = Env.websocket_url(env, true)
    assert url =~ "&remove_failed=true&"
    assert url =~ "ws://127.0.0.1:9/transport/websocket?"
    assert url =~ "language=elixir"
    assert url =~ "framework=exunit"
    assert url =~ "test_map=select"
    assert url =~ "reconnect=true"
    assert url =~ "metadata="
  end

  test "resolves build env from the transport binary" do
    binary = SelectiveExunit.Test.Drive.transport()

    previous = System.get_env()

    on_exit(fn ->
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "SELECTIVE_"))
      |> Enum.each(&System.delete_env/1)

      Enum.each(previous, fn {key, value} ->
        if String.starts_with?(key, "SELECTIVE_"), do: System.put_env(key, value)
      end)
    end)

    System.delete_env("SELECTIVE_TEST_MAP_DISABLE")

    System.put_env(%{
      "SELECTIVE_API_KEY" => "k",
      "SELECTIVE_HOST" => "ws://example.test",
      "SELECTIVE_PLATFORM" => "test",
      "SELECTIVE_RUN_ID" => "run",
      "SELECTIVE_RUN_ATTEMPT" => "1",
      "SELECTIVE_RUNNER_ID" => "runner/one",
      "SELECTIVE_BRANCH" => "main",
      "SELECTIVE_SHA" => "abc",
      "SELECTIVE_GIT_REPO" => "org/name",
      "SELECTIVE_GIT_PROVIDER" => "github"
    })

    assert {:ok, env} = Env.resolve(binary)
    assert env.api_key == "k"
    assert env.host == "ws://example.test"
    assert env.runner_id == "runner_one"
    assert env.test_map == "record"
    assert env.metadata["git_repo_full_name"] == "org/name"
  end

  test "names every missing SELECTIVE variable" do
    binary = SelectiveExunit.Test.Drive.transport()
    System.delete_env("SELECTIVE_API_KEY")
    System.put_env("SELECTIVE_HOST", "ws://example.test")
    assert {:error, message} = Env.resolve(binary)
    assert message =~ "SELECTIVE_API_KEY"
    assert message =~ "SELECTIVE_RUN_ID"
    System.delete_env("SELECTIVE_HOST")
  end

  test "reads build env from stdout while the transport writes to stderr" do
    transport = fake_transport(build_env(%{}))
    assert {:ok, env} = Env.resolve(transport)
    assert env.host == "wss://app.selective.ci"
  end

  test "rejects a host that is not a websocket url" do
    transport = fake_transport(build_env(%{"host" => "https://app.selective.ci"}))
    assert {:error, message} = Env.resolve(transport)

    assert message =~
             ~s(SELECTIVE_HOST must start with ws:// or wss://, got "https://app.selective.ci")
  end

  test "reports output that is not JSON" do
    transport = fake_transport("usage: transport <url>")
    assert {:error, message} = Env.resolve(transport)
    assert message =~ "transport --build-env printed invalid JSON"
  end

  defp build_env(overrides) do
    %{
      "api_key" => "k",
      "host" => "wss://app.selective.ci",
      "platform" => "test",
      "run_id" => "run",
      "run_attempt" => "1",
      "runner_id" => "runner",
      "branch" => "main",
      "sha" => "abc",
      "git_repo_full_name" => "org/name",
      "git_provider" => "github"
    }
    |> Map.merge(overrides)
    |> SelectiveExunit.JSON.encode()
  end

  defp fake_transport(stdout) do
    path = Path.join(System.tmp_dir!(), "fake-transport-#{System.unique_integer([:positive])}")

    File.write!(
      path,
      "#!/bin/sh\necho 'weak version GLIBC_2.39 not found' >&2\ncat <<'OUT'\n#{stdout}\nOUT\n"
    )

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
