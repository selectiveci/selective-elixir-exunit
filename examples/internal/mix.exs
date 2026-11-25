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
      test_elixirc_options: test_elixirc_options(),
      aliases: [
        test: [&mark_alias/1, "test --exclude alias_excluded", &record_compiler_options/1]
      ]
    ]
  end

  defp test_elixirc_options do
    if System.get_env("SELECTIVE_BAD_COMPILER_OPTION"),
      do: [not_a_compiler_option: true],
      else: []
  end

  defp record_compiler_options(_args) do
    if path = System.get_env("SELECTIVE_AFTER_OPTIONS_FILE") do
      File.write!(path, inspect(Code.get_compiler_option(:debug_info)))
    end
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
