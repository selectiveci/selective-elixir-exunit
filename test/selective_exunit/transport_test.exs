defmodule SelectiveExunit.TransportTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Transport

  setup do
    previous = System.get_env("SELECTIVE_TRANSPORT")
    on_exit(fn -> if previous, do: System.put_env("SELECTIVE_TRANSPORT", previous) end)
    System.delete_env("SELECTIVE_TRANSPORT")
    :ok
  end

  test "SELECTIVE_TRANSPORT wins and must exist" do
    System.put_env("SELECTIVE_TRANSPORT", "/no/such/transport")
    assert Transport.find() == {:error, "SELECTIVE_TRANSPORT=/no/such/transport does not exist"}
  end

  test "the pinned release downloads, verifies and installs a transport with --stdio" do
    assert {:ok, path} = Transport.find()

    assert path ==
             Path.join([
               Path.dirname(Mix.Project.build_path()),
               "selective_transport-v0.2.0",
               "transport"
             ])

    {help, 0} = System.cmd(path, ["--help"], stderr_to_stdout: true)
    assert help =~ "--stdio"
  end
end
