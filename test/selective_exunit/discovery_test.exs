defmodule SelectiveExunit.DiscoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SelectiveExunit.Discovery

  @mix_test_defaults if :infer_signatures in Code.available_compiler_options(),
                       do: [docs: false, debug_info: false, infer_signatures: false],
                       else: [docs: false, debug_info: false]
  @keys Keyword.keys(@mix_test_defaults) ++ [:ignore_module_conflict]

  setup do
    saved = current_options()
    Code.compiler_options(for key <- Keyword.keys(@mix_test_defaults), do: {key, true})
    on_exit(fn -> Code.compiler_options(saved) end)

    dir = Path.join(System.tmp_dir!(), "sel-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp current_options, do: for(key <- @keys, do: {key, Code.get_compiler_option(key)})

  defp probe_file(dir) do
    seen = Path.join(dir, "seen")
    file = Path.join(dir, "probe_test.exs")

    File.write!(file, """
    File.write!(#{inspect(seen)}, inspect(for key <- #{inspect(@keys)}, do: {key, Code.get_compiler_option(key)}))
    """)

    {file, seen}
  end

  defp options_seen_while_compiling(dir, project) do
    {file, seen} = probe_file(dir)
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

  test "keeps the options in effect after the test files are required", %{dir: dir} do
    project = [test_elixirc_options: [ignore_module_conflict: true]]
    options_seen_while_compiling(dir, project)

    for {key, value} <- @mix_test_defaults, do: assert(Code.get_compiler_option(key) == value)
    assert Code.get_compiler_option(:ignore_module_conflict) == true
  end

  test "restores the options when the test files fail to compile", %{dir: dir} do
    before = current_options()
    file = Path.join(dir, "broken_test.exs")
    File.write!(file, "defmodule Broken do\n")

    capture_io(:stderr, fn ->
      assert {:error, _message} = Discovery.require_test_files([file], [], [])
    end)

    assert current_options() == before
  end

  describe "with_test_compiler_options/2" do
    @project [test_elixirc_options: [ignore_module_conflict: true]]

    test "leaves the options alone until the test files are required", %{dir: dir} do
      before = current_options()

      Discovery.with_test_compiler_options(@project, fn ->
        assert current_options() == before
        options_seen_while_compiling(dir, @project)
        refute current_options() == before
      end)
    end

    test "restores the options, project entries included, after a normal return", %{dir: dir} do
      before = current_options()

      assert :done ==
               Discovery.with_test_compiler_options(@project, fn ->
                 options_seen_while_compiling(dir, @project)
                 :done
               end)

      assert current_options() == before
    end

    test "restores the options when the wrapped function raises", %{dir: dir} do
      before = current_options()

      assert_raise RuntimeError, "boom", fn ->
        Discovery.with_test_compiler_options(@project, fn ->
          options_seen_while_compiling(dir, @project)
          raise "boom"
        end)
      end

      assert current_options() == before
    end

    test "restores the options when the wrapped function throws an exit", %{dir: dir} do
      before = current_options()

      catch_exit(
        Discovery.with_test_compiler_options(@project, fn ->
          options_seen_while_compiling(dir, @project)
          exit(:aborted)
        end)
      )

      assert current_options() == before
    end
  end
end
