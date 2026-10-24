if Version.compare(System.version(), "1.18.0") == :lt do
  defmodule Internal.GroupModTest do
    use ExUnit.Case, async: true

    test "group one", do: assert(true)
  end
else
  defmodule Internal.GroupModTest do
    use ExUnit.Case, async: true, group: :db

    test "group one", do: assert(true)
  end
end
