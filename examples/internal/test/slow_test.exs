defmodule Internal.SlowTest do
  use ExUnit.Case

  test "slow" do
    File.write!(
      System.fetch_env!("SELECTIVE_SLOW_START"),
      Integer.to_string(System.monotonic_time())
    )

    Process.sleep(500)

    File.write!(
      System.fetch_env!("SELECTIVE_SLOW_END"),
      Integer.to_string(System.monotonic_time())
    )
  end

  test "stall" do
    File.write!(System.fetch_env!("SELECTIVE_STALL_START"), "1")
    Process.sleep(5_000)
  end

  test "after" do
    File.write!(
      System.fetch_env!("SELECTIVE_AFTER_START"),
      Integer.to_string(System.monotonic_time()) <> "\n",
      [:append]
    )
  end
end
