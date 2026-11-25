defmodule SelectiveExunit.Transport do
  @release "v0.3.0"
  @base_url "https://github.com/selectiveci/transport/releases/download"
  @checksums %{
    "transport-Linux-x86_64.tar.gz" =>
      "9a14ceee175a821977aedc69bfcbd9610ff369368a66274bdb64dbb5176bdc8d",
    "transport-Linux-aarch64.tar.gz" =>
      "7ff36a36c78347de37154f6eb461f425b9c7f87b5387d0288162092c6f54090c",
    "transport-Darwin-x86_64.tar.gz" =>
      "5f491c35d150e6594b4a81070060600af6721a1b558e0cdd2c47712027bb7ed2",
    "transport-Darwin-aarch64.tar.gz" =>
      "dc5e7fff627041d304ab88aabb21bbdb167a56a21d71c38b2850fc52d6cccd3c"
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

  def install(opts \\ []) do
    case System.get_env("SELECTIVE_TRANSPORT", "") do
      "" -> install_pinned(Keyword.get(opts, :if_missing, false))
      _ -> find()
    end
  end

  defp installed, do: install_pinned(true)

  defp install_pinned(if_missing) do
    path = pinned_path()

    if if_missing and File.regular?(path), do: {:ok, path}, else: install_to(path)
  end

  defp pinned_path do
    Path.join([
      Path.dirname(Mix.Project.build_path()),
      "selective_transport-#{@release}",
      "transport"
    ])
  end

  defp install_to(path) do
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
