defmodule Internal.Application do
  use Application

  def start(_type, _args) do
    if path = System.get_env("SELECTIVE_BOOT_FILE") do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "boot\n", [:append])
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Internal.Supervisor)
  end
end
