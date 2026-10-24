defmodule SelectiveExunit.Test.Socket do
  import Bitwise

  def start(opts \\ []) do
    parent = self()
    ready = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [
            :binary,
            packet: :raw,
            active: false,
            reuseaddr: true,
            ip: {127, 0, 0, 1}
          ])

        {:ok, port} = :inet.port(listen)
        send(parent, {ready, port})
        accept_loop(listen, parent, opts)
      end)

    receive do
      {^ready, port} -> %{pid: pid, port: port}
    after
      5_000 -> raise "socket listen failed"
    end
  end

  def await_open(timeout \\ 10_000) do
    receive do
      {:ws_open, pid, request} -> {pid, request}
    after
      timeout -> raise "timed out waiting for a websocket"
    end
  end

  def send_json(pid, map) do
    send(pid, {:send, SelectiveExunit.JSON.encode(map)})
    :ok
  end

  def recv_json(pid, timeout \\ 15_000) do
    receive do
      {:ws_frame, ^pid, text} ->
        SelectiveExunit.JSON.decode(text)

      {:ws_closed, ^pid} ->
        raise "websocket closed while waiting for a frame"
    after
      timeout -> raise "timed out waiting for a websocket frame"
    end
  end

  def close(pid), do: send(pid, :close_socket)

  defp accept_loop(listen, parent, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        if opts[:refuse] do
          :gen_tcp.close(socket)
          send(parent, :refused)
        else
          owner =
            spawn_link(fn ->
              receive do
                {:go, sock} -> handshake(sock, parent)
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, owner)
          send(owner, {:go, socket})
        end

        accept_loop(listen, parent, opts)

      {:error, :closed} ->
        :ok
    end
  end

  defp handshake(socket, parent) do
    {:ok, raw} = read_headers(socket, "")
    {head, rest} = split_headers(raw)
    [request | _] = String.split(head, "\r\n", parts: 2)

    cond do
      String.starts_with?(request, "POST ") ->
        body = read_body(socket, head, rest)
        send(parent, {:upload, self(), head, body})

        receive do
          {:respond, status} ->
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )

            :gen_tcp.close(socket)
        end

      true ->
        key = header(head, "sec-websocket-key")
        accept = websocket_accept(key)

        response = [
          "HTTP/1.1 101 Switching Protocols\r\n",
          "Upgrade: websocket\r\n",
          "Connection: Upgrade\r\n",
          "Sec-WebSocket-Accept: ",
          accept,
          "\r\n\r\n"
        ]

        :ok = :gen_tcp.send(socket, response)
        send(parent, {:ws_open, self(), head})
        :inet.setopts(socket, active: :once)
        ws_loop(socket, parent, rest)
    end
  end

  defp read_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 10_000) do
        {:ok, data} -> read_headers(socket, acc <> data)
        other -> other
      end
    end
  end

  defp split_headers(raw) do
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
    {head, rest}
  end

  defp read_body(socket, head, rest) do
    length = content_length(head)
    take_body(socket, rest, length)
  end

  defp take_body(_socket, acc, length) when byte_size(acc) >= length,
    do: binary_part(acc, 0, length)

  defp take_body(socket, acc, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 10_000)
    take_body(socket, acc <> data, length)
  end

  defp content_length(head) do
    case Regex.run(~r/content-length:\s*(\d+)/i, head) do
      [_, digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  defp header(head, name) do
    lines = String.split(head, "\r\n")

    Enum.find_value(lines, "", fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == name, do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp websocket_accept(key) do
    :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    |> Base.encode64()
  end

  defp ws_loop(socket, parent, buffer) do
    case decode_one(buffer) do
      {:ok, frame, rest} ->
        case handle_frame(socket, parent, frame) do
          :stop -> :ok
          :ok -> ws_loop(socket, parent, rest)
        end

      :incomplete ->
        receive do
          {:tcp, ^socket, data} ->
            :inet.setopts(socket, active: :once)
            ws_loop(socket, parent, buffer <> data)

          {:tcp_closed, ^socket} ->
            send(parent, {:ws_closed, self()})

          {:send, text} ->
            :gen_tcp.send(socket, encode_frame(text, 1))
            ws_loop(socket, parent, buffer)

          :close_socket ->
            :gen_tcp.close(socket)
            send(parent, {:ws_closed, self()})
        end
    end
  end

  defp handle_frame(_socket, parent, {:text, text}) do
    send(parent, {:ws_frame, self(), text})
    :ok
  end

  defp handle_frame(socket, _parent, {:ping, payload}) do
    :gen_tcp.send(socket, encode_frame(payload, 10))
    :ok
  end

  defp handle_frame(_socket, _parent, :ignore), do: :ok

  defp handle_frame(socket, parent, :close) do
    :gen_tcp.close(socket)
    send(parent, {:ws_closed, self()})
    :stop
  end

  defp decode_one(
         <<_::1, _rsv::3, opcode::4, 1::1, 126::7, len::16, mask::binary-size(4), rest::binary>>
       )
       when byte_size(rest) >= len do
    <<payload::binary-size(^len), leftover::binary>> = rest
    {:ok, frame(opcode, unmask(payload, mask)), leftover}
  end

  defp decode_one(
         <<_::1, _rsv::3, opcode::4, 1::1, 127::7, len::64, mask::binary-size(4), rest::binary>>
       )
       when byte_size(rest) >= len do
    <<payload::binary-size(^len), leftover::binary>> = rest
    {:ok, frame(opcode, unmask(payload, mask)), leftover}
  end

  defp decode_one(<<_::1, _rsv::3, opcode::4, 1::1, len::7, mask::binary-size(4), rest::binary>>)
       when len < 126 and byte_size(rest) >= len do
    <<payload::binary-size(^len), leftover::binary>> = rest
    {:ok, frame(opcode, unmask(payload, mask)), leftover}
  end

  defp decode_one(_buffer), do: :incomplete

  defp frame(1, payload), do: {:text, payload}
  defp frame(8, _payload), do: :close
  defp frame(9, payload), do: {:ping, payload}
  defp frame(_opcode, _payload), do: :ignore

  defp unmask(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      bxor(byte, :binary.at(mask, rem(index, 4)))
    end)
    |> :binary.list_to_bin()
  end

  defp encode_frame(payload, opcode) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<1::1, 0::3, opcode::4, 0::1, len::7>>
        len < 65_536 -> <<1::1, 0::3, opcode::4, 0::1, 126::7, len::16>>
        true -> <<1::1, 0::3, opcode::4, 0::1, 127::7, len::64>>
      end

    header <> payload
  end
end
