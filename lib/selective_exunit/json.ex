defmodule SelectiveExunit.JSON do
  @compile {:no_warn_undefined, :json}

  def encode(term) do
    term
    |> nulls()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  def decode(binary) when is_binary(binary) do
    :json.decode(binary)
  end

  defp nulls(nil), do: :null
  defp nulls(list) when is_list(list), do: Enum.map(list, &nulls/1)

  defp nulls(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, nulls(value)} end)
  end

  defp nulls(other), do: other
end
