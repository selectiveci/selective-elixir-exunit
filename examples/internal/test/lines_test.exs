defmodule Internal.LinesTest do
  use ExUnit.Case

  test "alpha", do: assert(true)
  test "beta", do: assert(true)

  @tag :alias_excluded
  test "excluded by the alias", do: assert(false)
end
