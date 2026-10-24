defmodule SelectiveExunit.Test.Drive do
  alias SelectiveExunit.Test.Child
  alias SelectiveExunit.Test.Socket

  def start(opts \\ []) do
    server = Socket.start(opts)

    dir =
      Path.join(
        System.tmp_dir!(),
        "selective-exunit-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    %{server: server, dir: dir}
  end

  def transport do
    System.get_env("SELECTIVE_TRANSPORT") || "/tmp/transport/target/release/transport"
  end

  def env(session, extra \\ %{}) do
    Map.merge(
      %{
        "SELECTIVE_TRANSPORT" => transport(),
        "SELECTIVE_API_KEY" => "test-key",
        "SELECTIVE_HOST" => "ws://127.0.0.1:#{session.server.port}",
        "SELECTIVE_PLATFORM" => "test",
        "SELECTIVE_RUN_ID" => "run-1",
        "SELECTIVE_RUN_ATTEMPT" => "1",
        "SELECTIVE_RUNNER_ID" => "runner-1",
        "SELECTIVE_BRANCH" => "main",
        "SELECTIVE_SHA" => "abc123",
        "SELECTIVE_GIT_REPO" => "selectiveci/selective-elixir-exunit",
        "SELECTIVE_GIT_PROVIDER" => "github",
        "SELECTIVE_TARGET_BRANCH" => "",
        "SELECTIVE_CONFORMANCE_FAST" => "1",
        "SELECTIVE_CONNECTED_TIMEOUT_MS" => "8000",
        "SELECTIVE_BOOT_FILE" => path(session, "boot"),
        "SELECTIVE_AFTER_SUITE_FILE" => path(session, "after"),
        "SELECTIVE_SETUP_ALL_FILE" => path(session, "setup"),
        "SELECTIVE_ON_EXIT_FILE" => path(session, "on_exit"),
        "SELECTIVE_FLAKE_FILE" => path(session, "flake"),
        "SELECTIVE_SLOW_START" => path(session, "slow_start"),
        "SELECTIVE_SLOW_END" => path(session, "slow_end"),
        "SELECTIVE_AFTER_START" => path(session, "after_start"),
        "SELECTIVE_STALL_START" => path(session, "stall_start"),
        "SELECTIVE_LATE_HOOK_FILE" => path(session, "late"),
        "SELECTIVE_ALIAS_FILE" => path(session, "alias")
      },
      extra
    )
  end

  def path(session, name), do: Path.join(session.dir, name)

  def lines(session, name) do
    file = path(session, name)

    if File.exists?(file) do
      file |> File.read!() |> String.split("\n", trim: true) |> length()
    else
      0
    end
  end

  def open(session, args \\ [], extra \\ %{}) do
    Child.open(args, env(session, extra))
  end

  def connect(session, args \\ [], extra \\ %{}) do
    child = open(session, args, extra)

    receive do
      {:ws_open, ws, request} ->
        Socket.send_json(ws, %{"command" => "connected"})
        {child, ws, request}

      {:child_exit, ref, output, status} when ref == child.ref ->
        raise "child exited #{status} before connecting\n#{output}"
    after
      60_000 ->
        raise "timed out waiting for a websocket\n" <> Child.output(child)
    end
  end

  def manifest(ws, configure \\ %{"tree" => true}) do
    Socket.send_json(ws, Map.merge(%{"command" => "configure_test_map"}, configure))
    Socket.send_json(ws, %{"command" => "test_manifest"})
    frame = Socket.recv_json(ws, 20_000)
    frame["data"]
  end

  def run_ids(ws, ids) do
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => ids})
    Enum.map(ids, fn _id -> Socket.recv_json(ws, 20_000) end)
  end

  def close(ws, status \\ nil) do
    Socket.send_json(ws, %{"command" => "close", "exit_status" => status})
    Socket.recv_json(ws, 20_000)
  end

  def query(request) do
    [start | _] = String.split(request, "\r\n")
    ["GET", path | _] = String.split(start, " ")
    URI.decode_query(URI.parse(path).query || "")
  end

  def by_description(cases, description) do
    Enum.find(cases, &(&1["description"] == description))
  end
end
