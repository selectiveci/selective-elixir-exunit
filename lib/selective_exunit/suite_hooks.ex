defmodule SelectiveExunit.SuiteHooks do
  def park do
    parked = Application.get_env(:ex_unit, :after_suite, []) ++ parked()
    ExUnit.configure(after_suite: [])
    SelectiveExunit.State.put(:parked_hooks, parked)
  end

  def run(stats) do
    park()
    Enum.each(parked(), & &1.(stats))
  end

  defp parked, do: SelectiveExunit.State.get(:parked_hooks)
end
