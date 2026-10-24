defmodule SelectiveExunit.RetryTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Retry

  test "backs off by min(attempt, 4) seconds" do
    System.delete_env("SELECTIVE_CONFORMANCE_FAST")
    assert Retry.delay_ms(1) == 1_000
    assert Retry.delay_ms(4) == 4_000
    assert Retry.delay_ms(9) == 4_000
  end

  test "conformance fast sleeps for zero" do
    System.put_env("SELECTIVE_CONFORMANCE_FAST", "1")
    assert Retry.delay_ms(4) == 0
  end

  test "reads the connected timeout override" do
    System.put_env("SELECTIVE_CONNECTED_TIMEOUT_MS", "250")
    assert Retry.connected_timeout_ms() == 250
    System.delete_env("SELECTIVE_CONNECTED_TIMEOUT_MS")
    assert Retry.connected_timeout_ms() == 30_000
  end
end
