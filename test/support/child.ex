defmodule SelectiveExunit.Test.Child do
  @ci ["GITHUB_ACTIONS", "CIRCLECI", "SEMAPHORE", "BUILDKITE", "RWX", "MINT"]

  def open(args, overrides, opts \\ []) do
    cd = Keyword.get(opts, :cd, Path.expand("examples/internal"))

    env = Map.merge(%{"MIX_ENV" => Atom.to_string(Mix.env())}, Map.new(overrides))

    parent = self()
    ready = make_ref()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        port =
          Port.open({:spawn_executable, System.find_executable("elixir")}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:cd, cd},
            {:args, ["-S", "mix", "selective.test" | args]},
            {:env, port_env(env)}
          ])

        send(parent, {ready, port})
        loop(parent, ref, port, "")
      end)

    receive do
      {^ready, port} -> %{pid: pid, port: port, ref: ref}
    after
      5_000 -> raise "child did not start"
    end
  end

  def await(handle, timeout \\ 90_000) do
    receive do
      {:child_exit, ref, output, status} when ref == handle.ref ->
        {output, status}
    after
      timeout ->
        kill(handle)
        raise "child timed out\n" <> output(handle)
    end
  end

  def output(handle) do
    send(handle.pid, {:output, self()})

    receive do
      {:output, text} -> text
    after
      1_000 -> ""
    end
  end

  def kill(handle), do: kill_os(handle.port)

  def signal(handle, name) do
    {:os_pid, pid} = Port.info(handle.port, :os_pid)
    System.cmd("kill", ["-#{name}", Integer.to_string(pid)])
  end

  defp loop(parent, ref, port, output) do
    receive do
      {^port, {:data, data}} ->
        loop(parent, ref, port, output <> IO.iodata_to_binary(data))

      {^port, {:exit_status, code}} ->
        send(parent, {:child_exit, ref, output, code})
        loop(parent, ref, port, output)

      {:output, pid} ->
        send(pid, {:output, output})
        loop(parent, ref, port, output)

      {:EXIT, ^parent, _reason} ->
        kill_os(port)

      {:EXIT, _other, _reason} ->
        loop(parent, ref, port, output)
    end
  end

  defp kill_os(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)])
      _ -> :ok
    end
  end

  defp port_env(env) do
    kept = Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    cleared =
      for {key, _value} <- System.get_env(),
          drop?(key),
          not Map.has_key?(env, key) do
        {to_charlist(key), false}
      end

    cleared ++ kept
  end

  defp drop?(key), do: key in @ci or String.starts_with?(key, "SELECTIVE_")
end
