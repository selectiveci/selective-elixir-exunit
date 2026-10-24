defmodule Internal.Helper do
  def check!(value) do
    if value != :ok, do: raise("shared helper rejected #{inspect(value)}")
    value
  end
end
