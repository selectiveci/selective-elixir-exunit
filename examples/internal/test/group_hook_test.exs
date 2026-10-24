defmodule Internal.GroupHookTest do
  use ExUnit.Case

  setup_all do
    setup = System.fetch_env!("SELECTIVE_SETUP_ALL_FILE")
    File.mkdir_p!(Path.dirname(setup))
    File.write!(setup, "setup\n", [:append])
    Process.sleep(100)

    on_exit(fn ->
      exit_path = System.fetch_env!("SELECTIVE_ON_EXIT_FILE")
      File.mkdir_p!(Path.dirname(exit_path))
      File.write!(exit_path, "exit\n", [:append])
      Process.sleep(50)
    end)

    :ok
  end

  test "one", do: assert(true)
  test "two", do: assert(true)
  test "three", do: assert(true)
end
