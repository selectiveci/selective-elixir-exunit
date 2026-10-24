defmodule Internal.RecordCalcTest do
  use ExUnit.Case

  @moduletag :recording

  test "adds", do: assert(Internal.Calc.add(1, 2) == 3)
  @tag :skip
  test "skipped", do: assert(Internal.Calc.add(1, 1) == 2)
end
