defmodule Internal.ConformanceTest do
  use ExUnit.Case

  @moduletag :conformance

  setup_all do
    Process.sleep(200)
  end

  test "pass", do: assert(1 + 1 == 2)
  test "fail", do: assert(1 + 1 == 3)

  @tag :skip
  test "pending", do: assert(false)

  test "flaky" do
    path = System.fetch_env!("SELECTIVE_FLAKE_FILE")
    count = if File.exists?(path), do: String.to_integer(String.trim(File.read!(path))), else: 0
    File.write!(path, Integer.to_string(count + 1))
    assert count >= 1
  end
end
