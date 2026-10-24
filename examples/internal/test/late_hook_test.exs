defmodule Internal.LateHookTest do
  use ExUnit.Case

  test "registers" do
    ExUnit.after_suite(fn _stats ->
      path = System.fetch_env!("SELECTIVE_LATE_HOOK_FILE")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "late\n", [:append])
    end)
  end
end
