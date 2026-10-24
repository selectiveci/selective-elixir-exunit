defmodule Internal.MixProject do
  use Mix.Project

  def project do
    [
      app: :internal,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths:
        if(System.get_env("SELECTIVE_NO_DEBUG_INFO"), do: ["lib", "nodebug"], else: ["lib"]),
      start_permanent: false,
      deps: [{:selective_exunit, path: "../.."}],
      aliases: [test: [&mark_alias/1, "test --exclude alias_excluded"]]
    ]
  end

  defp mark_alias(_args) do
    if path = System.get_env("SELECTIVE_ALIAS_FILE"), do: File.write!(path, "alias\n", [:append])
  end

  def application do
    [mod: {Internal.Application, []}, extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: ["selective.test": :test]]
  end
end
