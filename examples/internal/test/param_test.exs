if Version.compare(System.version(), "1.18.0") != :lt do
  defmodule Internal.ParamTest do
    use ExUnit.Case, parameterize: [%{n: 1}, %{n: 2}]

    test "parameterized", %{n: n} do
      assert n == 2
    end
  end
end
