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

  defp scoped(project, fun), do: Discovery.with_test_compiler_options(project, fun)

  defp require_probe(dir, project) do
    {file, seen} = probe_file(dir)
    assert {:ok, _modules} = Discovery.require_test_files([file], project, [])
    seen |> File.read!() |> Code.eval_string() |> elem(0)
  end

  test "compiles test files with mix test's default compiler options", %{dir: dir} do
    seen = scoped([], fn -> require_probe(dir, []) end)

    for {key, value} <- @mix_test_defaults, do: assert(seen[key] == value, "#{key}")
  end

  test "a project test_elixirc_options entry overrides a default and adds others", %{dir: dir} do
    project = [test_elixirc_options: [debug_info: true, ignore_module_conflict: true]]
    seen = scoped(project, fn -> require_probe(dir, project) end)

    assert seen[:debug_info] == true
    assert seen[:ignore_module_conflict] == true
    assert seen[:docs] == false
  end

  test "keeps the options in effect after the test files are required", %{dir: dir} do
    project = [test_elixirc_options: [ignore_module_conflict: true]]

    scoped(project, fn ->
      require_probe(dir, project)

      for {key, value} <- @mix_test_defaults, do: assert(Code.get_compiler_option(key) == value)
      assert Code.get_compiler_option(:ignore_module_conflict) == true
    end)
  end

  describe "with_test_compiler_options/2" do
    @project [test_elixirc_options: [ignore_module_conflict: true]]

    test "leaves the options alone until the test files are required", %{dir: dir} do
      before = current_options()

      scoped(@project, fn ->
        assert current_options() == before
        require_probe(dir, @project)
        refute current_options() == before
      end)
    end

    test "restores the options, project entries included, after a normal return", %{dir: dir} do
      before = current_options()

      assert :done == scoped(@project, fn -> require_probe(dir, @project) && :done end)
      assert current_options() == before
    end

    test "restores the options after the test files fail to compile", %{dir: dir} do
      before = current_options()
      file = Path.join(dir, "broken_test.exs")
      File.write!(file, "defmodule Broken do\n")

      capture_io(:stderr, fn ->
        scoped(@project, fn ->
          assert {:error, _message} = Discovery.require_test_files([file], @project, [])
        end)
      end)

      assert current_options() == before
    end

    test "restores the options when the wrapped function raises", %{dir: dir} do
      before = current_options()

      assert_raise RuntimeError, "boom", fn ->
        scoped(@project, fn ->
          require_probe(dir, @project)
          raise "boom"
        end)
      end

      assert current_options() == before
    end

    test "restores the options when the wrapped function exits", %{dir: dir} do
      before = current_options()

      catch_exit(
        scoped(@project, fn ->
          require_probe(dir, @project)
          exit(:aborted)
        end)
      )

      assert current_options() == before
    end

    test "an unknown project option raises from the require and the others are restored", %{
      dir: dir
    } do
      before = current_options()
      project = [test_elixirc_options: [not_a_compiler_option: true]]
      {file, _seen} = probe_file(dir)

      assert catch_error(
               scoped(project, fn ->
                 send(self(), :entered)
                 Discovery.require_test_files([file], project, [])
               end)
             )

      assert_received :entered
      assert current_options() == before
    end
  end
end
