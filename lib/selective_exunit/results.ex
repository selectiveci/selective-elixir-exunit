defmodule SelectiveExunit.Results do
  use Agent

  def start_link do
    Agent.start_link(
      fn ->
        %{
          results: %{},
          attempts: %{},
          current: nil,
          lost: false
        }
      end,
      name: __MODULE__
    )
  end

  def begin_attempt(id) do
    Agent.update(__MODULE__, fn state ->
      attempt = Map.get(state.attempts, id, 0) + 1

      %{
        state
        | attempts: Map.put(state.attempts, id, attempt),
          results: Map.delete(state.results, id),
          current: %{id: id, attempt: attempt}
      }
    end)
  end

  def current do
    Agent.get(__MODULE__, & &1.current)
  end

  def mark_lost do
    Agent.update(__MODULE__, &%{&1 | lost: true})
  end

  def clear_lost do
    Agent.update(__MODULE__, &%{&1 | lost: false})
  end

  def lost? do
    Agent.get(__MODULE__, & &1.lost)
  end

  def put(id, status, fields, attempt) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state.results, id) do
        %{status: "passed", attempt: ^attempt} when status == "pending" ->
          state

        _ ->
          result = Map.merge(fields, %{id: id, status: status, attempt: attempt})
          %{state | results: Map.put(state.results, id, result)}
      end
    end)
  end

  def emitted?(id) do
    Agent.get(__MODULE__, fn state -> Map.has_key?(state.results, id) end)
  end

  def remove_failed(id) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state.results, id) do
        %{status: "failed"} ->
          %{state | results: Map.delete(state.results, id)}

        _ ->
          state
      end
    end)
  end

  def framework_status do
    Agent.get(__MODULE__, fn state ->
      if Enum.any?(state.results, fn {_id, result} -> result.status == "failed" end) do
        Application.get_env(:ex_unit, :exit_status, 2)
      else
        0
      end
    end)
  end

  def stats do
    Agent.get(__MODULE__, fn state ->
      values = Map.values(state.results)

      %{
        total: length(values),
        failures: Enum.count(values, &(&1.status == "failed")),
        skipped: Enum.count(values, &(&1.status == "pending")),
        excluded: 0
      }
    end)
  end
end
