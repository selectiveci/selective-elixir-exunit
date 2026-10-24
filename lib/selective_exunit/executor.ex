defmodule SelectiveExunit.Executor do
  alias SelectiveExunit.Formatter
  alias SelectiveExunit.Recorder
  alias SelectiveExunit.Reporter
  alias SelectiveExunit.Results
  alias SelectiveExunit.State
  alias SelectiveExunit.SuiteHooks

  def run_batch(suite, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      if stopping?() or Results.lost?() do
        {:halt, :ok}
      else
        {:cont, run_id(suite, id)}
      end
    end)

    if Results.lost?() and not stopping?(), do: :lost, else: :ok
  end

  defp run_id(suite, id) do
    SuiteHooks.park()

    case Map.fetch(suite.index, id) do
      {:ok, test_case} ->
        Results.begin_attempt(id)
        State.put(:current_test, {test_case.module, test_case.name})
        Formatter.reset_notes()

        ExUnit.configure(
          only_test_ids: MapSet.new([{test_case.module, test_case.name}]),
          max_cases: 1,
          formatters: [SelectiveExunit.Formatter],
          capture_log: true
        )

        Recorder.reset()
        %{failures: failures} = ExUnit.run([test_case.module])
        State.put(:current_test, nil)
        notes = Formatter.take_notes()
        Recorder.collect(test_case, notes.tests)
        emit_id(id, notes, failures, test_case)

      :error ->
        Results.begin_attempt(id)
        Reporter.emit_uncollected(id)
    end

    :ok
  end

  defp emit_id(id, notes, failures, test_case) do
    cond do
      Results.lost?() ->
        :ok

      notes.tests == [] and not match?({:failed, _}, notes.module) and failures == 0 ->
        Reporter.emit_uncollected(id)

      true ->
        Reporter.emit_attempt(notes.tests, notes.module, failures, test_case)
    end
  end

  defp stopping?, do: State.get(:stopping)
end
