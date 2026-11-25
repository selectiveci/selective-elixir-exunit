defmodule Internal.CompilerOptionsTest do
  use ExUnit.Case

  test "records the compiler options in effect while tests run" do
    keys =
      Enum.filter(
        [:docs, :debug_info, :infer_signatures],
        &(&1 in Code.available_compiler_options())
      )

    seen = for key <- keys, do: {key, Code.get_compiler_option(key)}
    File.write!(System.fetch_env!("SELECTIVE_COMPILER_OPTIONS_FILE"), inspect(seen))
  end
end
