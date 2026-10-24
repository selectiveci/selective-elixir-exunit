defmodule Internal.SetupExitTest do
  use ExUnit.Case

  setup_all do
    on_exit(fn -> raise "setup boom" end)
    :ok
  end

  test "hooked", do: assert(true)
end
