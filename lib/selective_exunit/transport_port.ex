defmodule SelectiveExunit.TransportPort do
  use GenServer

  def start_link(binary, url) do
    token = make_ref()

    case GenServer.start_link(__MODULE__, {binary, url, self(), token}, name: __MODULE__) do
      {:ok, _pid} -> {:ok, token}
      other -> other
    end
  end

  def write(frame) when is_binary(frame) do
    GenServer.call(__MODULE__, {:write, frame}, :infinity)
  catch
    :exit, _reason -> {:error, :lost}
  end

  def shutdown do
    GenServer.call(__MODULE__, :shutdown, 5_000)
  catch
    :exit, _reason -> :ok
  end

  def init({binary, url, subscriber, token}) do
    port =
      Port.open({:spawn_executable, to_charlist(binary)}, [
        :binary,
        :exit_status,
        {:args, ["--stdio"]},
        {:env, [{~c"SELECTIVE_TRANSPORT_URL", to_charlist(url)}]},
        {:line, 16_777_216}
      ])

    {:ok, %{port: port, subscriber: subscriber, buffer: "", token: token}}
  end

  def handle_call({:write, frame}, _from, %{port: port} = state) when is_port(port) do
    result =
      try do
        true = Port.command(port, [frame, ?\n])
        :ok
      catch
        _, _ -> {:error, :lost}
      end

    {:reply, result, state}
  end

  def handle_call({:write, _frame}, _from, state) do
    {:reply, {:error, :lost}, state}
  end

  def handle_call(:shutdown, _from, state) do
    state = request_exit(state)
    {:stop, :normal, :ok, state}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    text = state.buffer <> IO.iodata_to_binary(line)
    send(state.subscriber, {:transport_line, state.token, text})
    {:noreply, %{state | buffer: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> IO.iodata_to_binary(chunk)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    send(state.subscriber, {:transport_lost, state.token, code})
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp request_exit(%{port: port} = state) when is_port(port) do
    try do
      Port.command(port, "exit\n")
    catch
      _, _ -> :ok
    end

    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      1_000 ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end
    end

    %{state | port: nil}
  end

  defp request_exit(state), do: state
end
