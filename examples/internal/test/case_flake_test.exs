defmodule Internal.CaseFlakeTest do
  use ExUnit.Case

  test "flakes" do
    path = System.fetch_env!("SELECTIVE_FLAKE_FILE")
    count = if File.exists?(path), do: String.to_integer(String.trim(File.read!(path))), else: 0
    File.write!(path, Integer.to_string(count + 1))
    assert count >= 1
  end
end
