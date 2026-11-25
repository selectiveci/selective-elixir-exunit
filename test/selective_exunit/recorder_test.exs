defmodule SelectiveExunit.RecorderTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SelectiveExunit.Recorder
  alias SelectiveExunit.State

  @test_file "test/recorded_test.exs"
  @internal "examples/internal/lib/internal"
  @calc "#{@internal}/calc.ex"
  @text "#{@internal}/text.ex"
  @clauses "#{@internal}/shapes/clauses.ex"
  @on_load_file "#{@internal}/shapes/on_load.ex"
  @injected "#{@internal}/shapes/injected.ex"

  @shapes %{
    "clauses.ex" => ~S"""
    defmodule Internal.Shapes.Clauses do
      def classify(1), do: :one
      def classify(n) when n > 5, do: :big

      def classify(n) do
        case rem(n, 2) do
          0 -> :even
          1 -> :odd
        end
      end
    end
    """,
    "on_load.ex" => ~S"""
    defmodule Internal.Shapes.OnLoad do
      @on_load :init

      def init, do: :ok
      def value, do: 1
    end
    """,
    "injected.ex" => ~S"""
    defmodule Internal.Shapes.Mixin do
      defmacro __using__(_opts) do
        quote do
          def injected, do: :injected
        end
      end
    end

    defmodule Internal.Shapes.Injected do
      use Internal.Shapes.Mixin
    end
    """
  }

  defp workloads do
    [
      {"none first", fn -> :ok end, [@test_file]},
      {"several",
       fn ->
         call(Internal.Calc, :add, [1, 2])
         call(Internal.Text, :shout, ["hi"])
         call(Internal.Shapes.Clauses, :classify, [4])
         call(Internal.Shapes.Injected, :injected)
       end, [@test_file, @calc, @text, @clauses, @injected]},
      {"none after several", fn -> :ok end, [@test_file]},
      {"one", fn -> call(Internal.Calc, :add, [1, 2]) end, [@test_file, @calc]},
      {"on_load module", fn -> call(Internal.Shapes.OnLoad, :value) end,
       [@test_file, @on_load_file]},
      {"none last", fn -> :ok end, [@test_file]}
    ]
  end

  setup do
    start_supervised!(%{id: State, start: {State, :start_link, []}})

    dir =
      Path.join(
        System.tmp_dir!(),
        "selective-exunit-recorder-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    binaries = compile_fixtures(dir)

    on_exit(fn ->
      :cover.stop()
      File.rm_rf!(dir)
      for {module, _binary} <- binaries, do: purge(module)
    end)

    %{dir: dir, binaries: Map.new(binaries)}
  end

  test "the native read records the same files per test as the cover analysis", %{dir: dir} do
    native = record_sequence(dir, :recorder)
    assert %{native: [_ | _], fallback: []} = State.get(:recording)
    cover = record_sequence(dir, :oracle)

    assert native == cover
    assert native == Enum.map(workloads(), fn {_name, _run, files} -> MapSet.new(files) end)
  end

  test "the cover fallback records the same files when no module reads natively", %{dir: dir} do
    force_fallback = fn ->
      State.update(:recording, &%{&1 | native: [], fallback: &1.native ++ &1.fallback})
    end

    fallback = record_sequence(dir, :recorder, force_fallback)
    assert %{native: [], fallback: [_ | _]} = State.get(:recording)

    assert fallback == record_sequence(dir, :oracle)
    assert fallback == Enum.map(workloads(), fn {_name, _run, files} -> MapSet.new(files) end)
  end

  test "a module whose native read fails falls back to cover and the rest still record", %{
    dir: dir,
    binaries: binaries
  } do
    reload_uninstrumented = fn ->
      purge(Internal.Shapes.Clauses)

      {:module, _} =
        :code.load_binary(
          Internal.Shapes.Clauses,
          ~c"clauses.beam",
          binaries[Internal.Shapes.Clauses]
        )
    end

    native = record_sequence(dir, :recorder, reload_uninstrumented)
    assert Internal.Shapes.Clauses in State.get(:recording).native
    assert native == record_sequence(dir, :oracle, reload_uninstrumented)
    assert Enum.at(native, 1) == MapSet.new([@test_file, @calc, @text, @injected])
  end

  defp call(module, function, args \\ []), do: apply(module, function, args)

  defp record_sequence(dir, mode, prepare \\ fn -> :ok end) do
    :cover.stop()
    State.put(:recording, nil)
    :ok = Recorder.start("", dir)
    prepare.()

    for {{_name, run, _files}, index} <- Enum.with_index(workloads()) do
      test_case = %{id: "test-#{index}", file_path: @test_file}

      case mode do
        :recorder ->
          Recorder.reset()
          run.()
          Recorder.collect(test_case, [%{state: nil}])
          State.get(:recording).deps[test_case.id]

        :oracle ->
          :ok = :cover.reset()
          run.()
          oracle_files(State.get(:recording).sources)
      end
    end
  end

  defp oracle_files(sources) do
    {:result, calls, _} = :cover.analyse(:calls, :module)

    files =
      for {module, count} <- calls, count > 0, Map.has_key?(sources, module), do: sources[module]

    MapSet.new([@test_file | files])
  end

  defp compile_fixtures(dir) do
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      compile_fixtures_with_debug_info(dir)
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end
  end

  defp compile_fixtures_with_debug_info(dir) do
    internal = Path.join(File.cwd!(), "examples/internal/lib/internal")

    from_files =
      for name <- ["calc.ex", "text.ex"],
          {module, binary} <- Code.compile_file(Path.join(internal, name)),
          do: {module, binary}

    from_strings =
      for {name, source} <- @shapes,
          {module, binary} <- Code.compile_string(source, Path.join([internal, "shapes", name])),
          do: {module, binary}

    for {module, binary} <- from_files ++ from_strings do
      File.write!(Path.join(dir, "#{module}.beam"), binary)
      {module, binary}
    end
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
