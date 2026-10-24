defmodule SelectiveExunit.Retry do
  def delay_ms(failures) when is_integer(failures) and failures > 0 do
    if fast?(), do: 0, else: min(failures, 4) * 1_000
  end

  def connected_timeout_ms do
    with value when is_binary(value) <- System.get_env("SELECTIVE_CONNECTED_TIMEOUT_MS"),
         {ms, ""} when ms > 0 <- Integer.parse(value) do
      ms
    else
      _ -> 30_000
    end
  end

  defp fast? do
    System.get_env("SELECTIVE_CONFORMANCE_FAST") == "1"
  end
end
