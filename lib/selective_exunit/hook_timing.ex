defmodule SelectiveExunit.HookTiming do
  use Agent

  def start_link do
    Agent.start_link(fn -> %{setup_all_us: 0, on_exit_us: 0} end, name: __MODULE__)
  end

  def add(key, us) when is_integer(us) and us > 0 do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, key, &(&1 + us))
    end)
  end

  def add(_key, _us), do: :ok

  def seconds do
    Agent.get(__MODULE__, fn state ->
      %{
        "seconds_in_setup_all_all_hooks" => state.setup_all_us / 1_000_000,
        "seconds_in_on_exit_all_hooks" => state.on_exit_us / 1_000_000
      }
    end)
  end

  def microseconds(started, finished) when is_integer(started) and is_integer(finished) do
    System.convert_time_unit(finished - started, :native, :microsecond)
  end

  def microseconds(_, _), do: 0
end
