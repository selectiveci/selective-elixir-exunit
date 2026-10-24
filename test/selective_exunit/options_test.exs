defmodule SelectiveExunit.OptionsTest do
  use ExUnit.Case, async: true

  alias SelectiveExunit.Options

  test "path:line is include location on this Mix" do
    assert Options.location_config(["test/example_test.exs:12"]) ==
             {["test/example_test.exs"],
              [exclude: [:test], include: [location: {"test/example_test.exs", 12}]]}

    assert Options.location_config(["test/example_test.exs"]) == {["test/example_test.exs"], []}

    assert Options.location_config(["test/example_test.exs:12:15"]) ==
             {["test/example_test.exs"],
              [exclude: [:test], include: [location: {"test/example_test.exs", [12, 15]}]]}

    assert Options.location_config(["foo:bar_test.exs:9"]) ==
             {["foo:bar_test.exs"],
              [exclude: [:test], include: [location: {"foo:bar_test.exs", 9}]]}
  end

  test "forwards include, exclude, only, and seed" do
    {opts, ["test/a_test.exs"]} =
      Options.parse([
        "--include",
        "focus",
        "--exclude",
        "slow",
        "--only",
        "line:1",
        "--seed",
        "7",
        "test/a_test.exs"
      ])

    config = Options.ex_unit_config(opts)
    assert config[:seed] == 7
    assert config[:max_cases] == 1
    assert config[:autorun] == false
    assert config[:capture_log] == true
    assert Keyword.has_key?(config, :include)
    assert :test in config[:exclude]
  end

  test "every mix test flag Selective cannot honor exits naming the flag" do
    for args <- [
          ["--cover"],
          ["--export-coverage", "x"],
          ["--stale"],
          ["--partitions", "2"],
          ["--max-cases", "2"],
          ["--max-failures", "1"],
          ["--repeat-until-failure", "3"],
          ["--breakpoints"],
          ["-b"],
          ["--listen-on-stdin"],
          ["--dry-run"],
          ["--raise"],
          ["--preload-modules"],
          ["--max-requires", "2"],
          ["--profile-require", "time"]
        ] do
      flag = if args == ["-b"], do: "--breakpoints", else: hd(args)
      assert {:error, message} = Options.parse(args)
      assert message == "mix selective.test does not support #{flag}"
    end
  end

  test "build flags pass through to compile and app.start" do
    args =
      ~w(--no-compile --no-start --no-deps-check --no-archives-check --no-elixir-version-check --force --all-warnings)

    assert {opts, []} = Options.parse(args)
    assert opts[:compile] == false and opts[:start] == false and opts[:force] == true
  end

  test "execution flags reach the ExUnit configuration" do
    {opts, []} =
      Options.parse(
        ~w(--exit-status 7 --no-color --formatter ExUnit.CLIFormatter --slowest 3 --slowest-modules 2 --timeout 9 --trace)
      )

    config = Options.ex_unit_config(opts)
    assert config[:exit_status] == 7
    assert config[:colors] == [enabled: false]
    assert config[:formatters] == [ExUnit.CLIFormatter]
    assert config[:slowest] == 3
    assert config[:slowest_modules] == 2
    assert config[:timeout] == 9
    assert config[:trace] == true
  end

  @tag skip: Version.match?(System.version(), "< 1.19.0")
  test "--name-pattern selects like mix test" do
    {opts, []} = Options.parse(["-n", "^test a$", "--name-pattern", "b"])
    config = Options.ex_unit_config(opts)
    assert [{:test, first}, {:test, second}] = config[:include]
    assert Regex.source(first) == "^test a$" and Regex.source(second) == "b"
    assert config[:exclude] == [:test]
    assert {:error, message} = Options.parse(["--name-pattern", "("])
    assert message =~ "--name-pattern"
  end

  @tag skip: Version.match?(System.version(), ">= 1.19.0")
  test "--name-pattern needs the Elixir that has it" do
    assert {:error, message} = Options.parse(["--name-pattern", "a"])
    assert message =~ "--name-pattern needs Elixir 1.19"
  end

  test "reports an unknown flag" do
    assert {:error, message} = Options.parse(["--not-a-flag"])
    assert message =~ "--not-a-flag"
    assert {:error, _} = Options.parse(["-t"])
  end
end
