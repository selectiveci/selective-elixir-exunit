defmodule Mix.Tasks.Selective.Test do
  use Mix.Task

  @shortdoc "Run ExUnit through Selective, or as mix test when Selective is not configured"

  def run(args) do
    code = SelectiveExunit.CLI.run(args)

    if is_integer(code) and code != 0 do
      System.at_exit(fn _ -> exit({:shutdown, code}) end)
    end

    :ok
  end
end
