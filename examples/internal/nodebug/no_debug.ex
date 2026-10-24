defmodule Internal.NoDebug do
  @compile {:debug_info, false}
  def ok, do: :ok
end
