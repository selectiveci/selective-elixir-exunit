defmodule SelectiveExunit.State do
  use Agent

  @empty_notes %{tests: [], module: nil}

  def start_link do
    Agent.start_link(
      fn ->
        %{
          forced_exit: nil,
          stopping: false,
          current_test: nil,
          run_notes: @empty_notes,
          user_formatters: [],
          started_at: nil,
          recording: nil,
          parked_hooks: []
        }
      end,
      name: __MODULE__
    )
  end

  def empty_notes, do: @empty_notes

  def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))

  def put(key, value), do: Agent.update(__MODULE__, &Map.replace!(&1, key, value))

  def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
end
