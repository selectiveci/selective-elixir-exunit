defmodule Internal.HelperFailTest do
  use ExUnit.Case

  @moduletag :shared_helper

  describe "shared" do
    test "first", do: Internal.Helper.check!(:first)
    test "second", do: Internal.Helper.check!(:second)
  end
end
