defmodule Mix.Tasks.Selective.Install do
  use Mix.Task

  @shortdoc "Installs the pinned Selective transport under _build"

  @impl true
  def run(args) do
    {opts, []} = OptionParser.parse_head!(args, strict: [if_missing: :boolean])
    Mix.Task.run("loadpaths")

    case SelectiveExunit.Transport.install(if_missing: opts[:if_missing] == true) do
      {:ok, path} -> Mix.shell().info("selective transport: #{path}")
      {:error, message} -> Mix.raise(message)
    end
  end
end
