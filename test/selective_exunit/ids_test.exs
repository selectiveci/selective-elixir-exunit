defmodule SelectiveExunit.IdsTest do
  use ExUnit.Case, async: true

  alias SelectiveExunit.Ids

  test "keeps a short module and name" do
    assert Ids.wire_id(Internal.CasePassTest, :"test passes") ==
             "Internal.CasePassTest.test passes"
  end

  test "shortens ids past 255 bytes and keeps them usable" do
    name = String.to_atom("test " <> String.duplicate("n", 240))
    id = Ids.wire_id(Internal.LongNameTest, name)
    assert byte_size(id) <= 255
    assert String.contains?(id, "~")
    assert String.ends_with?(id, Ids.sha256_hex("#{inspect(Internal.LongNameTest)}.#{name}"))
    assert Ids.usable?(id)
  end

  test "rejects a nul and invalid utf-8" do
    refute Ids.usable?("ok\0no")
    refute Ids.usable?(<<0xFF, 0xFE>>)
    shortened = Ids.shorten(<<0xFF, 0xFE>>)
    assert Ids.usable?(shortened)
  end

  test "a nul id shortens without keeping the nul" do
    raw = "ok" <> <<0>> <> "no"
    shortened = Ids.shorten(raw)
    assert Ids.usable?(shortened)
    refute String.contains?(shortened, <<0>>)
    assert String.ends_with?(shortened, Ids.sha256_hex(raw))
  end

  test "cuts the prefix on a grapheme boundary" do
    full = String.duplicate("é", 200)
    prefix = Ids.shorten(full) |> String.split("~") |> hd()
    assert String.valid?(prefix)
    assert byte_size(prefix) <= 190
  end

  test "suffixes duplicate wire ids" do
    pairs = [{"Same.Test", :a}, {"Same.Test", :b}]

    assert Ids.disambiguate(pairs) == [
             {"Same.Test", :a},
             {"Same.Test~2", :b}
           ]
  end
end
