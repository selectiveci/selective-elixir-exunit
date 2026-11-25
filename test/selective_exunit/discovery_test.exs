defmodule SelectiveExunit.DiscoveryTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Discovery

  @mix_test_defaults if Version.match?(System.version(), ">= 1.18.0"),
                       do: [docs: false, debug_info: false, infer_signatures: false],
                       else: [docs: false, debug_info: false]

  setup do
    keys = Keyword.keys(@mix_test_defaults) ++ [:ignore_module_conflict]
    saved = for key <- keys, do: {key, Code.get_compiler_option(key)}
    Code.compiler_options(for key <- Keyword.keys(@mix_test_defaults), do: {key, true})
    on_exit(fn -> Code.compiler_options(saved) end)

    dir = Path.join(System.tmp_dir!(), "sel-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp options_seen_while_compiling(dir, project) do
    seen = Path.join(dir, "seen")
    file = Path.join(dir, "probe_test.exs")

    File.write!(file, """
    keys = #{inspect(Keyword.keys(@mix_test_defaults) ++ [:ignore_module_conflict])}
    File.write!(#{inspect(seen)}, inspect(for key <- keys, do: {key, Code.get_compiler_option(key)}))
    """)

    assert {:ok, _modules} = Discovery.require_test_files([file], project, [])
    seen |> File.read!() |> Code.eval_string() |> elem(0)
  end

  test "compiles test files with mix test's default compiler options", %{dir: dir} do
    seen = options_seen_while_compiling(dir, [])

    for {key, value} <- @mix_test_defaults, do: assert(seen[key] == value, "#{key}")
  end

  test "a project test_elixirc_options entry overrides a default and adds others", %{dir: dir} do
    project = [test_elixirc_options: [debug_info: true, ignore_module_conflict: true]]
    seen = options_seen_while_compiling(dir, project)

    assert seen[:debug_info] == true
    assert seen[:ignore_module_conflict] == true
    assert seen[:docs] == false
  end

  test "restores the compiler options once the test files are compiled", %{dir: dir} do
    before = for {key, _} <- @mix_test_defaults, do: {key, Code.get_compiler_option(key)}

    options_seen_while_compiling(dir, [])

    assert for({key, _} <- before, do: {key, Code.get_compiler_option(key)}) == before
  end
end
