defmodule SelectiveExunit.UTF8 do
  def scrub(value) when is_binary(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      cleaned when is_binary(cleaned) ->
        cleaned

      {:error, good, rest} ->
        good <> scrub(drop_bad(rest))

      {:incomplete, good, _rest} ->
        good
    end
  end

  def scrub_list(list) when is_list(list), do: Enum.map(list, &scrub/1)

  defp drop_bad(<<_byte, rest::binary>>), do: rest
  defp drop_bad(<<>>), do: <<>>
end
