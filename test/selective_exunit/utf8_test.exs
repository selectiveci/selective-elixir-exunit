defmodule SelectiveExunit.UTF8Test do
  use ExUnit.Case, async: true

  alias SelectiveExunit.UTF8

  test "drops invalid bytes and keeps the valid prefix" do
    assert UTF8.scrub("ok" <> <<0xFF>> <> "tail") == "oktail"
    assert UTF8.scrub_list(["a" <> <<0x80>>, "b"]) == ["a", "b"]
  end
end
