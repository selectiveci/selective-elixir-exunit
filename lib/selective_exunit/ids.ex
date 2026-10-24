defmodule SelectiveExunit.Ids do
  @max_bytes 255
  @prefix_bytes 190

  def wire_id(module, name) do
    raw = "#{inspect(module)}.#{name}"

    if usable?(raw) do
      raw
    else
      shorten(raw)
    end
  end

  def usable?(id) when is_binary(id) do
    byte_size(id) <= @max_bytes and not String.contains?(id, <<0>>) and String.valid?(id)
  end

  def shorten(full) when is_binary(full) do
    prefix =
      full
      |> SelectiveExunit.UTF8.scrub()
      |> String.replace(<<0>>, "")
      |> utf8_prefix(@prefix_bytes)

    prefix <> "~" <> sha256_hex(full)
  end

  def disambiguate(pairs) when is_list(pairs) do
    {reversed, _seen} =
      Enum.reduce(pairs, {[], MapSet.new()}, fn {id, test}, {acc, seen} ->
        {unique, seen} = unique_id(id, id, seen, 2)

        if unique != id do
          IO.puts(
            :stderr,
            "selective_exunit: duplicate test id #{id} is listed as #{unique}"
          )
        end

        {[{unique, test} | acc], seen}
      end)

    Enum.reverse(reversed)
  end

  def sha256_hex(full) do
    :crypto.hash(:sha256, full) |> Base.encode16(case: :lower)
  end

  defp unique_id(candidate, original, seen, n) do
    if MapSet.member?(seen, candidate) do
      unique_id("#{original}~#{n}", original, seen, n + 1)
    else
      {candidate, MapSet.put(seen, candidate)}
    end
  end

  defp utf8_prefix(binary, max) when byte_size(binary) <= max, do: binary

  defp utf8_prefix(binary, max) do
    binary
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme

      if byte_size(next) <= max do
        {:cont, next}
      else
        {:halt, acc}
      end
    end)
  end
end
