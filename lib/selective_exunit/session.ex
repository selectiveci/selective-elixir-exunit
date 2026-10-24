defmodule SelectiveExunit.Session do
  alias SelectiveExunit.Env
  alias SelectiveExunit.Executor
  alias SelectiveExunit.Formatter
  alias SelectiveExunit.GitHints
  alias SelectiveExunit.HookTiming
  alias SelectiveExunit.JSON
  alias SelectiveExunit.Results
  alias SelectiveExunit.Retry
  alias SelectiveExunit.State
  alias SelectiveExunit.SuiteHooks
  alias SelectiveExunit.TransportPort

  @banner """
   ____       _           _   _
  / ___|  ___| | ___  ___| |_(_)_   _____
  \\___ \\ / _ \\ |/ _ \\/ __| __| \\ \\ / / _ \\
   ___) |  __/ |  __/ (__| |_| |\\ V /  __/
  |____/ \\___|_|\\___|\\___|\\__|_| \\_/ \\___|
  ________________________________________
  """

  def run(env, cases, opts) do
    Results.start_link()
    HookTiming.start_link()
    State.start_link()
    Formatter.start_user()
    trap_signals()
    SuiteHooks.park()

    suite = %{
      cases: cases,
      index: Map.new(cases, &{&1.id, &1}),
      tree: false,
      recording: :idle,
      connection_retries: 0,
      token: nil,
      modified: :omit,
      correlated: nil,
      transport: env.transport,
      env: env,
      debug: Keyword.get(opts, :debug, false),
      test_roots: test_roots()
    }

    suite = attach_git_hints(suite)
    connect_loop(suite, 0, false)
  end

  defp connect_loop(suite, failures, reconnect) do
    url = Env.websocket_url(suite.env, reconnect)

    case TransportPort.start_link(suite.transport, url) do
      {:ok, token} ->
        case drive(%{suite | token: token}) do
          {:exit, code} ->
            code

          {:reconnect, suite} ->
            TransportPort.shutdown()
            connect_loop(suite, failures, true)

          {:lost, suite} ->
            TransportPort.shutdown()
            retry_lost(suite, failures)
        end

      {:error, reason} ->
        IO.puts(:stderr, "connect failed (#{failures + 1}): #{inspect(reason)}")
        retry_lost(suite, failures)
    end
  end

  defp retry_lost(suite, failures) do
    failures = failures + 1
    suite = %{suite | connection_retries: failures}

    if failures > 10 do
      give_up(suite, failures)
    else
      Process.sleep(Retry.delay_ms(failures))
      connect_loop(suite, failures, true)
    end
  end

  defp give_up(suite, failures) do
    IO.puts(
      :stderr,
      "Selective could not reach #{suite.env.host} after #{failures} connection attempts"
    )

    1
  end

  defp drive(suite) do
    deadline = System.monotonic_time(:millisecond) + Retry.connected_timeout_ms()

    case wait_connected(suite, deadline, []) do
      {:ok, queued} ->
        Results.clear_lost()
        command_loop(suite, queued)

      :timeout ->
        IO.puts(:stderr, "timed out waiting for connected")
        TransportPort.shutdown()
        {:exit, 1}

      :lost ->
        {:lost, suite}

      {:unparseable, line} ->
        unparseable(line)
    end
  end

  defp wait_connected(suite, deadline, queued) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:transport_line, token, line} when token == suite.token ->
          case decode_command(line) do
            {:ok, %{"command" => "connected"}} ->
              {:ok, Enum.reverse(queued)}

            {:ok, command} ->
              wait_connected(suite, deadline, [command | queued])

            :ignore ->
              wait_connected(suite, deadline, queued)

            unparseable ->
              unparseable
          end

        {:transport_lost, token, _code} when token == suite.token ->
          :lost

        _other ->
          wait_connected(suite, deadline, queued)
      after
        remaining ->
          :timeout
      end
    end
  end

  defp command_loop(suite, queued) do
    case next_message(suite, queued) do
      {:lost, suite} ->
        {:lost, suite}

      {:unparseable, line} ->
        unparseable(line)

      {:command, command, queued} ->
        case dispatch(suite, command) do
          {:continue, suite} ->
            command_loop(suite, queued)

          other ->
            other
        end
    end
  end

  defp next_message(_suite, [command | rest]) do
    {:command, command, rest}
  end

  defp next_message(suite, []) do
    receive do
      {:transport_line, token, line} when token == suite.token ->
        case decode_command(line) do
          {:ok, command} -> {:command, command, []}
          :ignore -> next_message(suite, [])
          unparseable -> unparseable
        end

      {:transport_lost, token, _code} when token == suite.token ->
        {:lost, suite}

      _other ->
        next_message(suite, [])
    end
  end

  defp dispatch(suite, %{"command" => "configure_test_map"} = command) do
    {:continue, configure_test_map(suite, command)}
  end

  defp dispatch(suite, %{"command" => "test_manifest"}) do
    case TransportPort.write(JSON.encode(manifest_message(suite))) do
      :ok -> {:continue, suite}
      {:error, :lost} -> {:lost, suite}
    end
  end

  defp dispatch(suite, %{"command" => "run_test_cases"} = command) do
    ids = command["test_case_ids"] || []

    case Executor.run_batch(suite, ids) do
      :ok -> {:continue, suite}
      :lost -> {:lost, suite}
    end
  end

  defp dispatch(suite, %{"command" => "remove_failed_test_case_result"} = command) do
    id = command["test_case_id"]

    if is_binary(id) do
      Results.remove_failed(id)
    end

    {:continue, suite}
  end

  defp dispatch(suite, %{"command" => "reconnect"}) do
    {:reconnect, suite}
  end

  defp dispatch(suite, %{"command" => "close"} = command) do
    close_session(suite, command)
  end

  defp dispatch(suite, %{"command" => "print_notice", "message" => message})
       when is_binary(message) do
    unless Process.put(:selective_banner_shown, true), do: IO.puts(@banner)
    IO.puts(message)
    {:continue, suite}
  end

  defp dispatch(suite, %{"command" => "print_message", "message" => message})
       when is_binary(message) do
    IO.puts(IO.ANSI.format([:yellow, message]))
    {:continue, suite}
  end

  defp dispatch(suite, command) do
    if suite.debug do
      raise "unknown selective command #{inspect(command["command"])}"
    else
      {:continue, suite}
    end
  end

  defp configure_test_map(suite, command) do
    suite =
      if command["tree"] == true do
        %{suite | tree: true}
      else
        suite
      end

    if command["record"] == true and suite.recording == :idle do
      start_recording(suite)
    else
      suite
    end
  end

  defp start_recording(%{env: %{test_map: "record"}} = suite) do
    case SelectiveExunit.Recorder.start(GitHints.cwd_prefix(File.cwd!())) do
      :ok ->
        %{suite | recording: :on}

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Selective could not start test map recording (#{inspect(reason)}); tests run normally and this runner uploads no test map"
        )

        %{suite | recording: :off}
    end
  end

  defp start_recording(suite) do
    IO.puts(
      :stderr,
      "selective_exunit: test map recording was requested but this client advertises test_map=#{suite.env.test_map}; continuing without a trace"
    )

    %{suite | recording: :off}
  end

  defp manifest_message(suite) do
    data = %{"test_cases" => Enum.map(suite.cases, &case_json/1)}
    data = maybe_tree(data, suite)
    data = maybe_modified(data, suite)
    data = maybe_correlated(data, suite)
    %{"type" => "test_manifest", "data" => data}
  end

  defp case_json(test_case) do
    %{
      "id" => test_case.id,
      "file_path" => test_case.file_path,
      "line_number" => test_case.line_number,
      "description" => test_case.description,
      "full_description" => test_case.full_description,
      "run_time" => 0.0
    }
  end

  defp maybe_tree(data, %{tree: true, env: %{test_map: "0"}}) do
    warn_once("selective_exunit: test map is disabled; omitting the git snapshot")
    data
  end

  defp maybe_tree(data, %{tree: true, transport: binary}) do
    case GitHints.snapshot(binary) do
      {:ok, tree} -> Map.put(data, "test_map_tree", tree)
      :unavailable -> data
    end
  end

  defp maybe_tree(data, _suite), do: data

  defp maybe_modified(data, %{modified: :omit}), do: data
  defp maybe_modified(data, %{modified: files}), do: Map.put(data, "modified_test_files", files)

  defp maybe_correlated(data, %{correlated: nil}), do: data

  defp maybe_correlated(data, %{correlated: correlated}) do
    Map.put(data, "correlated_files", correlated)
  end

  defp close_session(suite, command) do
    forced =
      case command["exit_status"] do
        code when is_integer(code) -> code
        _ -> nil
      end

    State.put(:forced_exit, forced)

    send_report(suite)

    if forced == nil do
      Formatter.finish_user()
      SuiteHooks.run(Results.stats())
    end

    SelectiveExunit.Recorder.upload(suite.env, suite.transport)

    TransportPort.shutdown()
    {:exit, exit_code(forced)}
  end

  defp send_report(suite) do
    data =
      Map.merge(
        %{"connection_retries" => suite.connection_retries},
        HookTiming.seconds()
      )

    TransportPort.write(JSON.encode(%{"type" => "report_at_finish", "data" => data}))
  end

  defp exit_code(nil), do: Results.framework_status()
  defp exit_code(code) when is_integer(code), do: code

  defp attach_git_hints(%{env: %{target_branch: ""}} = suite), do: suite

  defp attach_git_hints(%{env: %{target_branch: target}} = suite) do
    cwd = File.cwd!()

    with {:ok, diff} <- warn_on_error(GitHints.diff(cwd, target)),
         modified = GitHints.modified_test_files(diff, cwd, suite.test_roots),
         {:ok, correlated} <-
           warn_on_error(GitHints.correlated_files(diff, cwd, target, suite.test_roots)) do
      %{suite | modified: modified, correlated: correlated}
    else
      :omit -> suite
    end
  end

  defp warn_on_error({:ok, value}), do: {:ok, value}

  defp warn_on_error({:error, message}) do
    IO.puts(:stderr, IO.ANSI.format([:yellow, message]))
    :omit
  end

  defp test_roots do
    project = Mix.Project.config()
    project[:test_paths] || ["test"]
  end

  defp decode_command(line) do
    case String.trim(line) do
      "" -> :ignore
      text -> decode_text(text)
    end
  end

  defp decode_text(text) do
    case JSON.decode(text) do
      %{"command" => _} = command -> {:ok, command}
      _ -> :ignore
    end
  rescue
    ErlangError -> {:unparseable, text}
  end

  defp unparseable(text) do
    IO.puts(:stderr, "Selective received a server frame it cannot parse: #{inspect(text)}")
    TransportPort.shutdown()
    {:exit, 1}
  end

  defp trap_signals do
    _ =
      System.trap_signal(:sigterm, fn ->
        State.put(:stopping, true)

        _ =
          TransportPort.write(
            JSON.encode(%{"type" => "terminating", "data" => %{"signal" => "TERM"}})
          )

        Process.sleep(250)
        TransportPort.shutdown()

        :erlang.halt(
          exit_code(State.get(:forced_exit)),
          [{:flush, false}]
        )
      end)

    :ok
  end

  defp warn_once(message) do
    unless Process.get(:selective_snapshot_warned) do
      Process.put(:selective_snapshot_warned, true)
      IO.puts(:stderr, message)
    end
  end
end
