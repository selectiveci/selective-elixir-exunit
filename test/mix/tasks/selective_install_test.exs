defmodule Mix.Tasks.Selective.InstallTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("SELECTIVE_TRANSPORT")
    on_exit(fn -> if previous, do: System.put_env("SELECTIVE_TRANSPORT", previous) end)
    System.delete_env("SELECTIVE_TRANSPORT")
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    binary = Path.join([dir, "_build", "selective_transport-v0.3.0", "transport"])
    {:ok, build_path: Path.join(dir, "_build"), binary: binary}
  end

  defp run_in(build_path, args) do
    Mix.Project.in_project(
      :install_fixture,
      Path.dirname(build_path),
      [build_path: build_path],
      fn _ ->
        Mix.Tasks.Selective.Install.run(args)
      end
    )
  end

  test "--if-missing is a no-op when the pinned binary is present", ctx do
    File.mkdir_p!(Path.dirname(ctx.binary))
    File.write!(ctx.binary, "sentinel")

    run_in(ctx.build_path, ["--if-missing"])

    assert File.read!(ctx.binary) == "sentinel"
    assert_received {:mix_shell, :info, ["selective transport: " <> path]}
    assert path == ctx.binary
  end

  test "installs a missing binary, and --if-missing then leaves it alone", ctx do
    run_in(ctx.build_path, ["--if-missing"])
    assert {help, 0} = System.cmd(ctx.binary, ["--help"], stderr_to_stdout: true)
    assert help =~ "--stdio"

    {:ok, before} = File.stat(ctx.binary, time: :posix)
    Process.sleep(1100)
    run_in(ctx.build_path, ["--if-missing"])
    assert {:ok, ^before} = File.stat(ctx.binary, time: :posix)
  end

  test "without the flag it reinstalls over an existing binary", ctx do
    File.mkdir_p!(Path.dirname(ctx.binary))
    File.write!(ctx.binary, "sentinel")

    run_in(ctx.build_path, [])

    assert File.read!(ctx.binary) != "sentinel"
  end

  test "SELECTIVE_TRANSPORT must exist and is not copied", ctx do
    System.put_env("SELECTIVE_TRANSPORT", "/no/such/transport")

    error = assert_raise Mix.Error, fn -> run_in(ctx.build_path, []) end
    assert error.message == "SELECTIVE_TRANSPORT=/no/such/transport does not exist"

    System.put_env("SELECTIVE_TRANSPORT", "/bin/echo")
    run_in(ctx.build_path, ["--if-missing"])
    refute File.exists?(ctx.binary)
  end
end
