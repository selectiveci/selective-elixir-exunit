defmodule SelectiveExunit.GitHints do
  alias SelectiveExunit.JSON

  def snapshot(binary) do
    case System.cmd(binary, ["--snapshot", File.cwd!()]) do
      {output, 0} ->
        {:ok, JSON.decode(String.trim(output))}

      {_output, _status} ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  @depth 1000

  def diff(cwd, target_branch) do
    refspec = "+refs/heads/#{target_branch}:refs/remotes/origin/#{target_branch}"

    with {:ok, _} <- git(cwd, ["fetch", "origin", refspec, "--depth=#{@depth}"], "fetch"),
         {:ok, output} <-
           git(cwd, ["diff", "origin/#{target_branch}", "--name-only"], "diff with") do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end

  def modified_test_files(diff, cwd, test_roots) do
    prefix = cwd_prefix(cwd)

    for path <- diff, test_file?(path, prefix, test_roots) do
      String.replace_prefix(path, prefix, "")
    end
  end

  def correlated_files(diff, cwd, target_branch, test_roots) do
    prefix = cwd_prefix(cwd)
    test? = &test_file?(&1, prefix, test_roots)

    args =
      ~w(log --no-merges --reverse --name-only --format=%x00 -n #{@depth} origin/#{target_branch})

    with {:ok, output} <- git(cwd, args, "read the history of") do
      commits =
        output
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&String.split(&1, "\n", trim: true))

      {:ok, correlate(commits, MapSet.new(Enum.reject(diff, test?)), test?, prefix)}
    end
  end

  def correlate(commits, code, test?, prefix) do
    {correlated, uncorrelated, _previous} =
      Enum.reduce(commits, {%{}, %{}, []}, fn files, {correlated, uncorrelated, previous} ->
        tests = files |> Enum.filter(test?) |> Enum.map(&String.replace_prefix(&1, prefix, ""))
        changed = Enum.filter(previous ++ files, &MapSet.member?(code, &1))

        correlated =
          for file <- changed, test <- tests, reduce: correlated do
            acc -> update_in(acc, [Access.key(file, %{}), Access.key(test, 0)], &(&1 + 1))
          end

        uncorrelated =
          if changed == [],
            do: Enum.reduce(tests, uncorrelated, &Map.update(&2, &1, 1, fn n -> n + 1 end)),
            else: uncorrelated

        {correlated, uncorrelated, files}
      end)

    %{"correlated_files" => correlated, "uncorrelated_files" => uncorrelated}
  end

  defp git(cwd, args, what) do
    if System.find_executable("git"),
      do: run_git(cwd, args, what),
      else: {:error, "Selective could not #{what} the target branch: git is not installed"}
  end

  defp run_git(cwd, args, what) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, _status} ->
        {:error,
         "Selective could not #{what} the target branch, so tests may run in a less useful order:\n#{String.trim(output)}"}
    end
  end

  def cwd_prefix(cwd) do
    case System.cmd("git", ["rev-parse", "--show-prefix"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> ""
    end
  end

  defp test_file?(path, prefix, test_roots) do
    case String.replace_prefix(path, prefix, "") do
      ^path when prefix != "" ->
        false

      relative ->
        String.ends_with?(relative, "_test.exs") and under_root?(relative, test_roots)
    end
  end

  defp under_root?(relative, roots) do
    Enum.any?(roots, fn root ->
      relative == root or String.starts_with?(relative, root <> "/")
    end)
  end
end
