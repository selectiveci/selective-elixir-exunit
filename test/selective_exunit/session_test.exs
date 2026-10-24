defmodule SelectiveExunit.SessionTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Test.Child
  alias SelectiveExunit.Test.Drive
  alias SelectiveExunit.Test.Socket

  @moduletag timeout: 120_000

  setup do
    session = Drive.start()
    on_exit(fn -> File.rm_rf!(session.dir) end)
    {:ok, session: session}
  end

  test "identity query advertises record and the key stays off argv", %{session: session} do
    {child, ws, request} = Drive.connect(session, [], %{"SELECTIVE_TARGET_BRANCH" => "main"})
    query = Drive.query(request)
    assert query["test_map"] == "record"
    assert query["language"] == "elixir"
    assert query["framework"] == "exunit"
    assert query["framework_version"] == System.version()
    assert query["api_key"] == "test-key"
    assert query["run_id"] == "run-1"
    assert query["runner_id"] == "runner-1"
    assert is_map(SelectiveExunit.JSON.decode(query["metadata"]))
    data = Drive.manifest(ws)
    assert is_map(data["test_map_tree"])
    assert is_binary(data["test_map_tree"]["sha"])
    assert is_map(data["test_map_tree"]["files"])
    assert is_list(data["test_map_tree"]["dirty"])
    assert is_list(data["modified_test_files"])
    assert is_map(data["correlated_files"])
    report = Drive.close(ws, nil)
    assert report["type"] == "report_at_finish"
    assert report["data"]["connection_retries"] == 0
    assert is_number(report["data"]["seconds_in_setup_all_all_hooks"])
    assert is_number(report["data"]["seconds_in_on_exit_all_hooks"])
    {_output, 0} = Child.await(child)
    assert Drive.lines(session, "boot") == 1
    assert Drive.lines(session, "after") == 1
  end

  test "group hooks count every assigned test across two batches", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    one = Drive.by_description(cases, "one")["id"]
    two = Drive.by_description(cases, "two")["id"]
    three = Drive.by_description(cases, "three")["id"]
    first = Drive.run_ids(ws, [one, two])
    second = Drive.run_ids(ws, [three])
    assert Enum.map(first ++ second, & &1["data"]["status"]) == ["passed", "passed", "passed"]
    report = Drive.close(ws, nil)
    assert report["data"]["seconds_in_setup_all_all_hooks"] >= 0.3
    assert report["data"]["seconds_in_on_exit_all_hooks"] >= 0.15
    {output, 0} = Child.await(child)
    assert occurrences(output, "Finished in") == 1
    assert Drive.lines(session, "setup") == 3
    assert Drive.lines(session, "on_exit") == 3
    assert Drive.lines(session, "after") == 1
    assert Drive.lines(session, "boot") == 1
  end

  test "a failed test exits 1 and a removed failure exits 0", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "fails")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "failed"
    assert hd(result["data"]["failure_formatted_backtrace"]) =~ "case_fail_test.exs:"
    Socket.send_json(ws, %{"command" => "remove_failed_test_case_result", "test_case_id" => id})
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "assign then assign keeps the latest flake attempt", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "flakes")["id"]
    [first] = Drive.run_ids(ws, [id])
    [second] = Drive.run_ids(ws, [id])
    assert first["data"]["status"] == "failed"
    assert second["data"]["status"] == "passed"
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "an unknown id fails and the batch continues", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    pass = Drive.by_description(cases, "passes")["id"]
    [missing, ran] = Drive.run_ids(ws, ["no-such-id", pass])
    assert missing["data"]["status"] == "failed"
    assert missing["data"]["failure_message_lines"] == ["test was not collected"]
    assert ran["data"]["status"] == "passed"
    Drive.close(ws, nil)
    {_output, 2} = Child.await(child)
  end

  test "a skipped assignment is pending", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "pending")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "pending"
    assert is_binary(result["data"]["pending_message"])
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "a long id is shortened on the manifest and the result", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    long = Enum.find(cases, &(byte_size(&1["id"]) > 64 and String.contains?(&1["id"], "~")))
    assert long
    assert byte_size(long["id"]) <= 255
    [result] = Drive.run_ids(ws, [long["id"]])
    assert result["data"]["id"] == long["id"]
    assert result["data"]["status"] == "passed"
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "path:line keeps the named example", %{session: session} do
    line = line_of("examples/internal/test/lines_test.exs", "test \"beta\"")
    {child, ws, _request} = Drive.connect(session, ["test/lines_test.exs:#{line}"])
    cases = Drive.manifest(ws)["test_cases"]
    assert Enum.map(cases, & &1["description"]) == ["beta"]
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "an integer close skips after_suite and wins over the framework status", %{
    session: session
  } do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "passes")["id"]
    Drive.run_ids(ws, [id])
    Drive.close(ws, 2)
    {_output, 2} = Child.await(child)
    assert Drive.lines(session, "after") == 0
    assert Drive.lines(session, "boot") == 1
  end

  test "an integer close before any test is the process status", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    Drive.close(ws, 2)
    {_output, 2} = Child.await(child)
    assert Drive.lines(session, "after") == 0
  end

  test "commands queued before connected run after it", %{session: session} do
    child = Drive.open(session)
    {ws, _request} = Socket.await_open()
    Socket.send_json(ws, %{"command" => "print_message", "message" => "queued-notice"})
    Socket.send_json(ws, %{"command" => "connected"})
    Drive.close(ws, nil)
    {output, 0} = Child.await(child)
    assert output =~ "queued-notice"
  end

  test "an unparseable frame exits 1", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    send(ws, {:send, "{not json"})
    {output, 1} = Child.await(child)
    assert output =~ ~s(Selective received a server frame it cannot parse: "{not json")
  end

  test "an unknown command is ignored", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    Socket.send_json(ws, %{"command" => "not-a-command"})
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "a clean reconnect does not increment connection retries", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    Socket.send_json(ws, %{"command" => "reconnect"})
    {ws, request} = Socket.await_open()
    assert Drive.query(request)["reconnect"] == "true"
    Socket.send_json(ws, %{"command" => "connected"})
    report = Drive.close(ws, nil)
    assert report["data"]["connection_retries"] == 0
    {_output, 0} = Child.await(child)
  end

  test "a dropped socket keeps a failure the server already accepted", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    fails = Drive.by_description(cases, "fails")["id"]
    slow = Drive.by_description(cases, "slow")["id"]
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => [fails, slow]})
    failed = Socket.recv_json(ws, 20_000)
    assert failed["data"]["status"] == "failed"
    assert failed["data"]["id"] == fails
    wait_until(fn -> File.exists?(Drive.path(session, "slow_start")) end)
    Socket.close(ws)
    {ws, _request} = Socket.await_open(20_000)
    Socket.send_json(ws, %{"command" => "connected"})
    [result] = Drive.run_ids(ws, [slow])
    assert result["data"]["status"] == "passed"
    Drive.close(ws, nil)
    {_output, 2} = Child.await(child)
  end

  test "a dropped socket counts a retry and reruns the lost batch", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "slow")["id"]
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => [id]})
    wait_until(fn -> File.exists?(Drive.path(session, "slow_start")) end)
    Socket.close(ws)
    {ws, request} = Socket.await_open(20_000)
    assert Drive.query(request)["reconnect"] == "true"
    Socket.send_json(ws, %{"command" => "connected"})
    File.rm(Drive.path(session, "slow_start"))
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "passed"
    report = Drive.close(ws, nil)
    assert report["data"]["connection_retries"] == 1
    {_output, 0} = Child.await(child)
  end

  test "a second batch stays behind the one already running", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    slow = Drive.by_description(cases, "slow")["id"]
    later = Drive.by_description(cases, "after")["id"]
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => [slow]})
    wait_until(fn -> File.exists?(Drive.path(session, "slow_start")) end)
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => [later]})
    assert Socket.recv_json(ws, 20_000)["data"]["id"] == slow
    assert Socket.recv_json(ws, 20_000)["data"]["id"] == later

    started =
      Drive.path(session, "slow_end") |> File.read!() |> String.trim() |> String.to_integer()

    followed =
      Drive.path(session, "after_start") |> File.read!() |> String.trim() |> String.to_integer()

    assert started < followed
    assert Drive.lines(session, "after_start") == 1
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "SIGTERM during a batch does not start the next test", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    stall = Drive.by_description(cases, "stall")["id"]
    later = Drive.by_description(cases, "after")["id"]
    Socket.send_json(ws, %{"command" => "run_test_cases", "test_case_ids" => [stall, later]})
    wait_until(fn -> File.exists?(Drive.path(session, "stall_start")) end)
    Child.signal(child, "TERM")
    frame = Socket.recv_json(ws, 2_000)
    assert frame["type"] == "terminating"
    assert frame["data"]["signal"] == "TERM"
    Child.await(child, 4_000)
    refute File.exists?(Drive.path(session, "after_start"))
  end

  test "SIGTERM after a failure exits with the --exit-status failure status", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["--exit-status", "7"])
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "fails")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "failed"
    Child.signal(child, "TERM")
    frame = Socket.recv_json(ws, 10_000)
    assert frame["type"] == "terminating"
    assert frame["data"]["signal"] == "TERM"
    {_output, 7} = Child.await(child, 10_000)
  end

  test "eleven refused connections exit 1", %{session: _session} do
    session = Drive.start(refuse: true)
    on_exit(fn -> File.rm_rf!(session.dir) end)
    child = Drive.open(session)
    {output, 1} = Child.await(child, 30_000)
    assert output =~ ~r"Selective could not reach ws://127.0.0.1:\d+ after 11 connection attempts"
  end

  test "waiting forever for connected exits 1", %{session: session} do
    child = Drive.open(session, [], %{"SELECTIVE_CONNECTED_TIMEOUT_MS" => "400"})
    {output, 1} = Child.await(child, 15_000)
    assert output =~ "timed out waiting for connected"
  end

  test "a disabled test map omits the snapshot", %{session: session} do
    {child, ws, request} = Drive.connect(session, [], %{"SELECTIVE_TEST_MAP_DISABLE" => "1"})
    assert Drive.query(request)["test_map"] == "0"
    data = Drive.manifest(ws, %{"tree" => true, "record" => true})
    refute Map.has_key?(data, "test_map_tree")
    Drive.close(ws, nil)
    {output, 0} = Child.await(child)
    assert output =~ "omitting the git snapshot"
    assert occurrences(output, "this client advertises test_map=0") == 1
  end

  test "a record run uploads each test's own files with explicit ids", %{session: session} do
    {child, ws, request} = Drive.connect(session, ["--only", "recording"])
    assert Drive.query(request)["test_map"] == "record"
    cases = Drive.manifest(ws, %{"tree" => true, "record" => true})["test_cases"]
    shouts = Drive.by_description(cases, "shouts")["id"]
    adds = Drive.by_description(cases, "adds")["id"]
    skipped = Drive.by_description(cases, "skipped")["id"]
    results = Drive.run_ids(ws, [shouts, adds, skipped]) ++ Drive.run_ids(ws, [adds])
    assert Enum.map(results, & &1["data"]["status"]) == ["passed", "passed", "pending", "passed"]
    Drive.close(ws, nil)
    assert_receive {:upload, pid, head, body}, 20_000
    send(pid, {:respond, 204})
    {_output, 0} = Child.await(child)
    assert head =~ "POST /test_maps/fragments?run_id=run-1&run_attempt=1&runner_id=runner-1 "
    assert head =~ ~r/authorization: [^\r]*test-key/i

    assert fragment_deps(body) == %{
             shouts => [
               "examples/internal/lib/internal/text.ex",
               "examples/internal/test/record_text_test.exs"
             ],
             adds => [
               "examples/internal/lib/internal/calc.ex",
               "examples/internal/test/record_calc_test.exs"
             ]
           }
  end

  test "SELECTIVE_TEST_MAP_IGNORE leaves out every path under its prefixes", %{session: session} do
    ignore = "examples/internal/lib/internal/text.ex, examples/internal/test/record_calc"

    {child, ws, _request} =
      Drive.connect(session, ["--only", "recording"], %{"SELECTIVE_TEST_MAP_IGNORE" => ignore})

    cases = Drive.manifest(ws, %{"tree" => true, "record" => true})["test_cases"]
    shouts = Drive.by_description(cases, "shouts")["id"]
    adds = Drive.by_description(cases, "adds")["id"]
    Drive.run_ids(ws, [shouts, adds])
    Drive.close(ws, nil)
    assert_receive {:upload, pid, _head, body}, 20_000
    send(pid, {:respond, 204})
    {_output, 0} = Child.await(child)

    assert fragment_deps(body) == %{
             shouts => ["examples/internal/test/record_text_test.exs"],
             adds => ["examples/internal/lib/internal/calc.ex"]
           }
  end

  test "a failed upload warns once and keeps the exit status", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["--only", "recording"])
    cases = Drive.manifest(ws, %{"tree" => true, "record" => true})["test_cases"]
    Drive.run_ids(ws, [Drive.by_description(cases, "adds")["id"]])
    Drive.close(ws, nil)

    stamps =
      for _attempt <- 1..3 do
        assert_receive {:upload, pid, _head, _body}, 20_000
        send(pid, {:respond, 500})
        System.monotonic_time(:millisecond)
      end

    {output, 0} = Child.await(child)
    assert List.last(stamps) - hd(stamps) >= 3_000
    assert occurrences(output, "Selective could not upload this runner's test map") == 1
    refute_received {:upload, _pid, _request, _body}
  end

  for {cause, env, reason} <- [
        {"cover is already running", %{"SELECTIVE_COVER_TAKEN" => "1"}, "already_started"},
        {"a module has no debug info", %{"SELECTIVE_NO_DEBUG_INFO" => "1"},
         "Elixir.Internal.NoDebug.beam"}
      ] do
    @tag child_env: env, reason: reason
    test "a recorder that cannot start because #{cause} warns once and uploads nothing", %{
      session: session,
      child_env: env,
      reason: reason
    } do
      {child, ws, request} = Drive.connect(session, ["--only", "recording"], env)
      assert Drive.query(request)["test_map"] == "record"
      Socket.send_json(ws, %{"command" => "configure_test_map", "record" => true})
      cases = Drive.manifest(ws, %{"record" => true, "tree" => false})["test_cases"]
      results = Drive.run_ids(ws, Enum.map(cases, & &1["id"]))

      assert Enum.sort(Enum.map(results, & &1["data"]["status"])) ==
               ["passed", "passed", "passed", "pending"]

      Drive.close(ws, nil)
      {output, 0} = Child.await(child)

      assert [line] =
               Enum.filter(
                 String.split(output, "\n"),
                 &String.contains?(&1, "could not start test map recording")
               )

      assert line =~ reason
      refute_received {:upload, _pid, _request, _body}
    end
  end

  test "a test that stops cover ends recording with one warning and no upload", %{
    session: session
  } do
    {child, ws, _request} =
      Drive.connect(session, ["--only", "recording"], %{"SELECTIVE_STOP_COVER" => "1"})

    cases = Drive.manifest(ws, %{"tree" => true, "record" => true})["test_cases"]
    ids = Enum.map(["shouts", "stops cover", "adds"], &Drive.by_description(cases, &1)["id"])
    results = Drive.run_ids(ws, ids)
    assert Enum.map(results, & &1["data"]["status"]) == ["passed", "passed", "passed"]
    Drive.close(ws, nil)
    {output, 0} = Child.await(child)
    assert occurrences(output, "Selective stopped test map recording") == 1
    refute_received {:upload, _pid, _request, _body}
  end

  @tag skip: Version.compare(System.version(), "1.18.0") == :lt
  test "a parameterized test fails when any parameter fails", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["test/param_test.exs"])
    cases = Drive.manifest(ws)["test_cases"]
    assert length(cases) == 1
    id = Drive.by_description(cases, "parameterized")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "failed"
    message = Enum.join(result["data"]["failure_message_lines"], "\n")
    assert message =~ "Parameters:"
    Drive.close(ws, nil)
    {_output, 2} = Child.await(child)
  end

  test "a setup_all on_exit failure fails the run", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["test/setup_exit_test.exs"])
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "hooked")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "failed"
    assert Enum.join(result["data"]["failure_message_lines"], "\n") =~ "setup boom"
    Drive.close(ws, nil)
    {_output, status} = Child.await(child)
    assert status != 0
  end

  test "--slowest reaches the user formatter replay", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["--slowest", "1"])
    cases = Drive.manifest(ws)["test_cases"]
    Drive.run_ids(ws, [Drive.by_description(cases, "passes")["id"]])
    Drive.close(ws, nil)
    {output, 0} = Child.await(child)
    assert output =~ "Internal.CasePassTest [test/case_pass_test.exs]"
    assert output =~ "Top 1 slowest"

    {child, ws, _request} = Drive.connect(session, ["--slowest", "1"])
    Drive.manifest(ws)
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "the test alias steps run first and its test arguments apply", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["test/lines_test.exs"])
    cases = Drive.manifest(ws)["test_cases"]
    refute Enum.any?(cases, &(&1["description"] == "excluded by the alias"))
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
    assert Drive.lines(session, "alias") == 1
  end

  @tag skip: Version.match?(System.version(), "< 1.19.0")
  test "--name-pattern narrows the manifest", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["-n", "^test (alpha|beta)$"])
    cases = Drive.manifest(ws)["test_cases"]
    assert Enum.map(cases, & &1["description"]) |> Enum.sort() == ["alpha", "beta"]
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "stacked only filters keep async and custom tests", %{session: session} do
    {child, ws, _request} =
      Drive.connect(session, ["--only", "async:true", "--only", "custom:true"])

    cases = Drive.manifest(ws)["test_cases"]

    assert MapSet.new(cases, & &1["description"]) ==
             MapSet.new(["async one", "group one", "sync one"])

    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "a failing run prints the failure once", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "fails")["id"]
    [result] = Drive.run_ids(ws, [id])
    assert result["data"]["status"] == "failed"
    assert eventually(fn -> Child.output(child) =~ "Assertion with ==" end)
    Socket.send_json(ws, %{"command" => "print_notice", "message" => "Runner ID: runner-1"})
    Socket.send_json(ws, %{"command" => "print_notice", "message" => "Test selection: all"})

    Socket.send_json(ws, %{"command" => "close", "exit_status" => nil, "message" => "closing now"})

    assert Socket.recv_json(ws)["type"] == "report_at_finish"
    {output, 2} = Child.await(child)
    assert occurrences(output, "Assertion with ==") == 1
    assert occurrences(output, "Finished in") == 1
    assert occurrences(output, "|____/") == 1
    assert output =~ "Test selection: all"
    refute output =~ "closing now"
  end

  test "failures in one shared helper share their first frame", %{session: session} do
    {child, ws, _request} = Drive.connect(session, ["--only", "shared_helper"])
    cases = Drive.manifest(ws)["test_cases"]

    assert Enum.map(cases, &{&1["description"], &1["full_description"]}) |> Enum.sort() == [
             {"first", "Internal.HelperFailTest shared first"},
             {"second", "Internal.HelperFailTest shared second"}
           ]

    results = Drive.run_ids(ws, Enum.map(cases, & &1["id"]))
    [first, second] = Enum.map(results, &hd(&1["data"]["failure_formatted_backtrace"]))
    assert first == second
    assert first =~ "lib/internal/helper.ex:"

    assert Enum.all?(
             results,
             &(&1["data"]["failure_formatted_backtrace"]
               |> Enum.any?(fn frame -> frame =~ "test/helper_fail_test.exs:" end))
           )

    refute Enum.any?(
             results,
             &Enum.any?(&1["data"]["failure_message_lines"], fn line -> line =~ "\n" end)
           )

    Drive.close(ws, nil)
    {_output, 2} = Child.await(child)
  end

  test "an after_suite registered during a test runs once", %{session: session} do
    {child, ws, _request} = Drive.connect(session)
    cases = Drive.manifest(ws)["test_cases"]
    id = Drive.by_description(cases, "registers")["id"]
    Drive.run_ids(ws, [id])
    assert Drive.lines(session, "late") == 0
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
    assert Drive.lines(session, "late") == 1
    assert Drive.lines(session, "after") == 1
  end

  test "a child does not inherit GITHUB_ACTIONS", %{session: _session} do
    System.put_env("GITHUB_ACTIONS", "true")
    on_exit(fn -> System.delete_env("GITHUB_ACTIONS") end)
    child = Child.open(["test/case_pass_test.exs"], %{})
    {_output, 0} = Child.await(child)
  end

  test "plain mix selective.test is mix test", %{session: _session} do
    child = Child.open(["test/case_pass_test.exs"], %{})
    {_output, 0} = Child.await(child)

    child = Child.open(["test/case_fail_test.exs"], %{})
    {_output, status} = Child.await(child)
    assert status == 2
  end

  test "--failed uses the mix failure manifest", %{session: session} do
    child = Child.open(["test/case_fail_test.exs"], %{})
    {_output, 2} = Child.await(child)
    {child, ws, _request} = Drive.connect(session, ["--failed"])
    cases = Drive.manifest(ws)["test_cases"]
    assert Enum.map(cases, & &1["description"]) == ["fails"]
    Drive.close(ws, nil)
    {_output, 0} = Child.await(child)
  end

  test "rejected modes and a missing binary exit 1", %{session: session} do
    child = Drive.open(session, ["--cover"])
    {output, 1} = Child.await(child)
    assert output =~ "--cover"

    child = Drive.open(session, ["--stale"])
    {output, 1} = Child.await(child)
    assert output =~ "stale"

    child = Drive.open(session, ["--partitions", "2"])
    {output, 1} = Child.await(child)
    assert output =~ "partitions"

    child =
      Child.open([], %{
        "SELECTIVE_API_KEY" => "k",
        "SELECTIVE_TRANSPORT" => "/no/such/transport"
      })

    {output, 1} = Child.await(child)
    assert output =~ "SELECTIVE_TRANSPORT=/no/such/transport does not exist"
  end

  test "a startup failure prints the error block, and --debug the stack trace", %{
    session: session
  } do
    child = Drive.open(session, [], %{"SELECTIVE_TRANSPORT" => "/bin/echo"})
    {output, 1} = Child.await(child)
    assert output =~ "Selective could not start"
    assert output =~ "transport --build-env printed invalid JSON"
    refute output =~ "** ("

    unrunnable = Drive.path(session, "unrunnable")
    File.write!(unrunnable, "")
    child = Drive.open(session, [], %{"SELECTIVE_TRANSPORT" => unrunnable})
    {output, 1} = Child.await(child)
    assert output =~ "Selective could not start"
    refute output =~ "** ("

    child = Drive.open(session, ["--debug"], %{"SELECTIVE_TRANSPORT" => unrunnable})
    {output, 1} = Child.await(child)
    assert output =~ "** (ErlangError)"
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  defp fragment_deps(body) do
    fragment = SelectiveExunit.JSON.decode(:zlib.gunzip(body))
    1 = fragment["version"]

    Map.new(fragment["tests"], fn test ->
      {test["id"], Enum.map(test["deps"], &Enum.at(fragment["files"], &1))}
    end)
  end

  defp occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp line_of(path, needle) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, needle))
    |> Kernel.+(1)
  end

  defp wait_until(fun) do
    Enum.reduce_while(1..50, nil, fn _try, _acc ->
      if fun.() do
        {:halt, :ok}
      else
        Process.sleep(50)
        {:cont, nil}
      end
    end)
  end
end
