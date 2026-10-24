defmodule SelectiveExunit.Formatter do
  use GenServer

  alias SelectiveExunit.State

  def start_user do
    formatters = Application.get_env(:ex_unit, :formatters)
    opts = user_opts()

    pids =
      Enum.map(formatters, fn formatter ->
        {:ok, pid} = GenServer.start_link(formatter, opts)
        GenServer.cast(pid, {:suite_started, opts})
        pid
      end)

    State.put(:user_formatters, pids)
    State.put(:started_at, System.monotonic_time())
  end

  def finish_user do
    run =
      System.convert_time_unit(
        System.monotonic_time() - State.get(:started_at),
        :native,
        :microsecond
      )

    Enum.each(State.get(:user_formatters), fn pid ->
      GenServer.cast(pid, {:suite_finished, %{async: 0, load: 0, run: run}})
      GenServer.stop(pid, :normal, :infinity)
    end)

    State.put(:user_formatters, [])
  end

  def reset_notes, do: State.put(:run_notes, State.empty_notes())

  def take_notes do
    notes = State.get(:run_notes)
    reset_notes()
    notes
  end

  def init(_opts) do
    {:ok, %{module_at: nil, test_done_at: nil, counting: false}}
  end

  def handle_cast({:module_started, test_module} = event, state) do
    if current_module?(test_module), do: forward(event)
    {:noreply, %{state | module_at: System.monotonic_time(), counting: false, test_done_at: nil}}
  end

  def handle_cast({:test_started, test} = event, state) do
    if current?(test) do
      forward(event)

      SelectiveExunit.HookTiming.add(
        :setup_all_us,
        SelectiveExunit.HookTiming.microseconds(state.module_at, System.monotonic_time())
      )

      {:noreply, %{state | counting: true}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:test_finished, test} = event, state) do
    if current?(test) do
      note_test(test)
      forward(event)
      {:noreply, %{state | test_done_at: System.monotonic_time()}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:module_finished, test_module} = event, state) do
    if state.counting do
      SelectiveExunit.HookTiming.add(
        :on_exit_us,
        SelectiveExunit.HookTiming.microseconds(state.test_done_at, System.monotonic_time())
      )

      note_module(test_module.state)
    end

    if current_module?(test_module), do: forward(event)

    {:noreply, %{state | counting: false}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    SelectiveExunit.SuiteHooks.park()
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp note_test(test) do
    update_notes(fn notes -> %{notes | tests: notes.tests ++ [test]} end)
  end

  defp note_module({:failed, _} = state) do
    update_notes(fn notes ->
      case notes.module do
        {:failed, _} -> notes
        _ -> %{notes | module: state}
      end
    end)
  end

  defp note_module(_state), do: :ok

  defp update_notes(fun), do: State.update(:run_notes, fun)

  defp forward(event), do: Enum.each(State.get(:user_formatters), &GenServer.cast(&1, event))

  defp current_module?(test_module) do
    match?({mod, _name} when mod == test_module.name, State.get(:current_test))
  end

  defp current?(test) do
    case State.get(:current_test) do
      {mod, name} -> test.module == mod and test.name == name
      _ -> false
    end
  end

  defp user_opts do
    defaults = [
      seed: 0,
      max_cases: 1,
      colors: [],
      trace: false,
      slowest: 0,
      slowest_modules: 0,
      exclude: [],
      include: [],
      dry_run: false,
      repeat_until_failure: 0
    ]

    Keyword.merge(defaults, ExUnit.configuration())
  end
end
