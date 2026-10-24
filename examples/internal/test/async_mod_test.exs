defmodule Internal.AsyncModTest do
  use ExUnit.Case, async: true

  test "async one", do: assert(true)
end
