defmodule Internal.RecordTextTest do
  use ExUnit.Case

  @moduletag :recording

  test "shouts", do: assert(Internal.Text.shout("hi") == "HI!")

  test "stops cover" do
    if System.get_env("SELECTIVE_STOP_COVER"), do: :cover.stop()
  end
end
