defmodule SelectiveExunit.Transport do
  @release "v0.2.0"
  @base_url "https://github.com/selectiveci/transport/releases/download"
  @checksums %{
    "transport-Linux-x86_64.tar.gz" =>
      "87b2d6847ed0efa44c73ec16526b85134bf6f2e3759d99f925682eaf1b27d937",
    "transport-Linux-aarch64.tar.gz" =>
      "cf54fbf596b8a708fbc64e031f98737f076b8c32c371a4506c8141c49bca84be",
    "transport-Darwin-x86_64.tar.gz" =>
      "ccb9f795086d5584ff605cff8aefc534a82cde3154a3231f7f9396cde27bf7d4",
    "transport-Darwin-aarch64.tar.gz" =>
      "7dcaec969378a181a62749673b9c0b658be17bf16a8880f5effbd8e03a6c4a17"
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
