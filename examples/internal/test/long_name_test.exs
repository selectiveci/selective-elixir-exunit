defmodule Internal.LongNameTest do
  use ExUnit.Case

  for name <- [String.duplicate("n", 240)] do
    test name do
      assert true
    end
  end
end
