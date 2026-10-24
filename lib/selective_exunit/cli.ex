defmodule SelectiveExunit.CLI do
  alias SelectiveExunit.Discovery
  alias SelectiveExunit.Env
  alias SelectiveExunit.Options
  alias SelectiveExunit.Session

  @otp_floor 27
  @header "Selective could not start. Rerun with --debug, or contact support at https://selective.ci/support"

  def run(args) do
    if Env.wants_connection?() do
      start(args)
    else
      Mix.Task.rerun("test", args)
      0
    end
  end

  defp start(args) do
    otp = List.to_integer(:erlang.system_info(:otp_release))

    cond do
      otp < @otp_floor ->
        IO.puts(
          :stderr,
          "selective_exunit requires Erlang/OTP #{@otp_floor} or later (this is OTP #{otp})"
        )

        1

      System.get_env("MIX_ENV") == nil and Mix.env() != :test ->
        abort("""
        mix selective.test is running in the "#{Mix.env()}" environment. Set MIX_ENV=test, or add
        def cli, do: [preferred_envs: ["selective.test": :test]] to your mix.exs.\
        """)

      true ->
        test_alias = Discovery.test_alias()
        code = connect(test_alias, test_alias.args ++ args)
        Enum.each(test_alias.after, &Discovery.run_step/1)
        code
    end
  end

  defp connect(test_alias, args) do
    case Options.parse(args) do
      {:error, message} ->
        abort(message)

      {opts, files} ->
        case prepare(test_alias, opts, files, args) do
          {:ok, env, cases} -> Session.run(env, cases, opts)
          {:error, message} -> abort(message)
        end
    end
  end

  defp prepare(test_alias, opts, files, args) do
    with {:ok, binary} <- SelectiveExunit.Transport.find(),
         {:ok, env} <- Env.resolve(binary),
         :ok <- Enum.each(test_alias.before, &Discovery.run_step/1),
         {:ok, cases} <- Discovery.load(opts, files, args) do
      {:ok, Map.put(env, :transport, binary), cases}
    end
  rescue
    error ->
      if opts[:debug],
        do: reraise(error, __STACKTRACE__),
        else: {:error, Exception.message(error)}
  end

  defp abort(message) do
    text = Enum.map_join([@header | String.split(message, "\n")], "\n", &"  #{&1}")
    IO.puts(:stderr, IO.ANSI.format([:red, "\n", text, "\n"]))
    1
  end
end
