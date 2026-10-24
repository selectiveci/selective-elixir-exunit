defmodule SelectiveExunit.SuiteHooksTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.SuiteHooks

  test "park clears the callbacks and run invokes each once" do
    start_supervised!(%{
      id: SelectiveExunit.State,
      start: {SelectiveExunit.State, :start_link, []}
    })

    previous = Application.get_env(:ex_unit, :after_suite, [])
    parent = self()

    ExUnit.configure(after_suite: [fn stats -> send(parent, {:hook, stats.total}) end])

    SuiteHooks.park()
    assert Application.get_env(:ex_unit, :after_suite) == []
    assert SuiteHooks.run(%{total: 2, failures: 0, skipped: 0, excluded: 0}) == :ok
    assert_received {:hook, 2}

    ExUnit.configure(after_suite: previous)
  end
end
