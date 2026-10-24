defmodule SelectiveExunit.GitHintsTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.GitHints

  test "correlates the diff's code files with tests in the same or the next commit" do
    commits = [
      ["lib/billing.ex", "test/billing_test.exs"],
      ["test/billing_test.exs", "test/other_test.exs"],
      ["lib/unrelated.ex", "test/unrelated_test.exs"],
      ["test/lonely_test.exs"]
    ]

    test? = &String.ends_with?(&1, "_test.exs")

    assert GitHints.correlate(commits, MapSet.new(["lib/billing.ex"]), test?, "") == %{
             "correlated_files" => %{
               "lib/billing.ex" => %{"test/billing_test.exs" => 2, "test/other_test.exs" => 1}
             },
             "uncorrelated_files" => %{
               "test/unrelated_test.exs" => 1,
               "test/lonely_test.exs" => 1
             }
           }
  end

  test "a depth-1 checkout fetches the target branch and hints only from the diff" do
    parent = Path.join(System.tmp_dir!(), "sel-git-#{System.os_time(:nanosecond)}")
    origin = Path.join(parent, "origin")
    on_exit(fn -> File.rm_rf(parent) end)

    commit(origin, %{"lib/a.ex" => "1", "test/a_test.exs" => "1"}, init: true)
    commit(origin, %{"lib/a.ex" => "2", "test/a2_test.exs" => "2"})
    commit(origin, %{"lib/b.ex" => "3", "test/b_test.exs" => "3"})
    git!(origin, ["checkout", "-q", "-b", "pr"])
    commit(origin, %{"lib/a.ex" => "4", "test/c_test.exs" => "4"})

    clone = Path.join(parent, "clone")
    git!(parent, ["clone", "-q", "--depth", "1", "--branch", "pr", "file://" <> origin, clone])

    assert {:ok, diff} = GitHints.diff(clone, "main")
    assert Enum.sort(diff) == ["lib/a.ex", "test/c_test.exs"]
    assert GitHints.modified_test_files(diff, clone, ["test"]) == ["test/c_test.exs"]

    assert {:ok, hints} = GitHints.correlated_files(diff, clone, "main", ["test"])
    assert Map.keys(hints["correlated_files"]) == ["lib/a.ex"]

    assert hints["correlated_files"]["lib/a.ex"] == %{
             "test/a_test.exs" => 1,
             "test/a2_test.exs" => 2,
             "test/b_test.exs" => 1
           }

    assert {:error, message} = GitHints.diff(clone, "no-such-branch")
    assert message =~ "Selective could not fetch the target branch"

    path = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      assert GitHints.diff(clone, "main") ==
               {:error, "Selective could not fetch the target branch: git is not installed"}
    after
      System.put_env("PATH", path)
    end
  end

  test "modified test files stay inside this project and its test roots" do
    diff = ["test/ok_test.exs", "testing/no_test.exs", "examples/internal/test/inner_test.exs"]
    repo = Path.join(System.tmp_dir!(), "sel-git-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf(repo) end)
    commit(repo, %{"examples/internal/test/.keep" => ""}, init: true)

    assert GitHints.modified_test_files(diff, repo, ["test"]) == ["test/ok_test.exs"]

    assert GitHints.modified_test_files(diff, Path.join(repo, "examples/internal"), ["test"]) ==
             ["test/inner_test.exs"]
  end

  defp commit(repo, files, opts \\ []) do
    if opts[:init] do
      File.mkdir_p!(repo)
      git!(repo, ["init", "-q", "-b", "main"])
    end

    for {path, body} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), body)
    end

    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "c"])
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
  end
end
