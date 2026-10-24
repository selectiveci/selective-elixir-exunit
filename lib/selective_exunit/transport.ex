defmodule SelectiveExunit.Transport do
  @release "v0.1.2"
  @base_url "https://github.com/selectiveci/transport/releases/download"
  @checksums %{
    "transport-Linux-x86_64.tar.gz" =>
      "d8e0b8f31fc006313ecc207866c0dbcdeab11ad583ee3bbf767abed3d95592a1",
    "transport-Linux-aarch64.tar.gz" =>
      "4f200250adda3bf304947607471ed6e8c7f5b9881d093395d4c49796fc9d3655",
    "transport-Darwin-x86_64.tar.gz" =>
      "1b81a4840dcdacc47f44539c90bd5711efc4a99e4c18d211e5ff3d56bc9fff34",
    "transport-Darwin-aarch64.tar.gz" =>
      "4f3dfb8d1ee40066984d9a1fafa0eb3362290fdfadf06dd516ab52241fec4c39"
  }

  def find do
    case System.get_env("SELECTIVE_TRANSPORT", "") do
      "" ->
        installed()

      path ->
        if File.regular?(path),
          do: {:ok, path},
          else: {:error, "SELECTIVE_TRANSPORT=#{path} does not exist"}
    end
  end

  defp installed do
    path =
      Path.join([
        Path.dirname(Mix.Project.build_path()),
        "selective_transport-#{@release}",
        "transport"
      ])

    if File.regular?(path), do: {:ok, path}, else: install(path)
  end

  defp install(path) do
    with {:ok, asset} <- asset(),
         url = "#{@base_url}/#{@release}/#{asset}",
         {:ok, archive} <- download(url),
         :ok <- verify(archive, @checksums[asset], url),
         {:ok, binary} <- extract(archive, url) do
      place(binary, path, url)
    end
  end

  defp asset do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    os =
      case :os.type() do
        {:unix, :linux} -> "Linux"
        {:unix, :darwin} -> "Darwin"
        other -> inspect(other)
      end

    asset = "transport-#{os}-#{if arch == "arm64", do: "aarch64", else: arch}.tar.gz"

    if Map.has_key?(@checksums, asset),
      do: {:ok, asset},
      else:
        {:error,
         "transport #{@release} has no #{asset}; set SELECTIVE_TRANSPORT to a transport binary"}
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    agent = {~c"user-agent", ~c"selective_exunit/#{SelectiveExunit.version()}"}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    get =
      &:httpc.request(:get, {to_charlist(url), [agent]}, [ssl: ssl], [body_format: :binary] ++ &1)

    response =
      case get.([]) do
        {:error, {:header_too_long, _}} -> get.(max_header_size: 65_536)
        response -> response
      end

    case response do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "could not download #{url}: HTTP #{status}"}

      {:error, reason} ->
        {:error, "could not download #{url}: #{inspect(reason)}"}
    end
  end

  defp verify(archive, expected, url) do
    actual = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "#{url} has sha256 #{actual}, expected #{expected}"}
  end

  defp extract(archive, url) do
    case :erl_tar.extract({:binary, archive}, [:compressed, :memory, files: [~c"transport"]]) do
      {:ok, [{_name, binary}]} -> {:ok, binary}
      _ -> {:error, "#{url} does not contain a transport binary"}
    end
  end

  defp place(binary, path, url) do
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    File.write!(tmp, binary)
    File.chmod!(tmp, 0o755)

    {help, status} = System.cmd(tmp, ["--help"], stderr_to_stdout: true)

    cond do
      help =~ "--stdio" ->
        File.rename!(tmp, path)
        {:ok, path}

      String.trim(help) == "" ->
        File.rm!(tmp)
        {:error, "the transport from #{url} cannot run on this host (exit #{status})"}

      true ->
        File.rm!(tmp)

        {:error,
         "the transport from #{url} has no --stdio mode, which this client needs; set SELECTIVE_TRANSPORT to a newer transport binary"}
    end
  end
end
