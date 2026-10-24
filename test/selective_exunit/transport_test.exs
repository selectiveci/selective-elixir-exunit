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

  test "the pinned release downloads, verifies and refuses a transport without --stdio" do
    assert {:error, message} = Transport.find()
    assert message =~ "transport-Linux-x86_64.tar.gz has no --stdio mode"

    refute File.exists?(
             Path.join([
               Path.dirname(Mix.Project.build_path()),
               "selective_transport-v0.1.2",
               "transport"
             ])
           )
  end
end
