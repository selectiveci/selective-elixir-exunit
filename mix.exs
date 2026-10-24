defmodule SelectiveExunit.MixProject do
  use Mix.Project

  def project do
    [
      app: :selective_exunit,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Selective client for ExUnit",
      package: package()
    ]
  end

  def cli do
    [preferred_envs: ["selective.test": :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, inets: :optional, ssl: :optional, tools: :optional]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps, do: []

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/selectiveci/selective-elixir-exunit"},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
