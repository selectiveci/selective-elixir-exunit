defmodule Mix.Tasks.Selective.DeadCode do
  use Mix.Task

  @shortdoc "Fail on dead code or an in-VM fragment upload"

  @fix "Delete the code or add a caller in this slice."
  @special ~w(
    __block__ __aliases__ alias def defp defmacro defmacrop defmodule
    import require quote unquote unquote_splicing when
  )a

  def run(_args) do
    findings = findings() |> Enum.reject(&allowed?/1) |> Enum.sort_by(& &1.sort)

    if findings == [] do
      Mix.shell().info("selective.dead_code: no dead code or later-slice upload in lib/")
    else
      Mix.raise(Enum.map_join(findings, "\n\n", & &1.message))
    end
  end

  defp findings do
    ctx = scan(Path.wildcard("lib/**/*.ex"))
    compiled = compile(ctx.files)

    try do
      clauses = clause_findings(ctx)
      lines = MapSet.new(clauses, & &1.sort)

      clauses ++
        Enum.reject(compiler_findings(compiled), &(&1.sort in lines)) ++
        export_findings(compiled.dest, ctx) ++
        ctx.uploads
    after
      File.rm_rf(compiled.dest)
    end
  end

  defp scan(files) do
    Enum.reduce(files, empty(files), fn file, ctx ->
      ast = file |> File.read!() |> Code.string_to_quoted!(file: file)
      walk(ast, %{ctx | file: file})
    end)
  end

  defp empty(files) do
    %{
      file: nil,
      files: files,
      mod: nil,
      aliases: %{},
      clauses: [],
      calls: [],
      uploads: []
    }
  end

  defp compile(files) do
    dest =
      Path.join(System.tmp_dir!(), "selective-dead-code-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dest)
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      result = Kernel.ParallelCompiler.compile_to_path(files, dest, return_diagnostics: true)
      %{dest: dest, result: result}
    after
      Code.compiler_options(previous)
    end
  end

  defp clause_findings(ctx) do
    ctx.clauses
    |> Enum.group_by(&{&1.mod, &1.name, &1.arity})
    |> Enum.flat_map(fn {{mod, name, arity}, group} ->
      dead_clauses(ctx.calls, mod, name, arity, Enum.sort_by(group, & &1.line))
    end)
  end

  defp dead_clauses(calls, mod, name, arity, group) when length(group) > 1 do
    relevant =
      Enum.filter(calls, fn call ->
        call.mod == mod and call.name == name and length(call.args) == arity
      end)

    cond do
      relevant == [] ->
        []

      Enum.any?(relevant, &(not literal_call?(&1))) ->
        []

      true ->
        case selected_lines(relevant, group) do
          :unknown ->
            []

          selected ->
            for clause <- group, clause.line not in selected do
              clause_finding(clause, name, arity)
            end
        end
    end
  end

  defp dead_clauses(_calls, _mod, _name, _arity, _group), do: []

  defp literal_call?(call), do: Enum.all?(call.args, &literal?/1)

  defp literal?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?(_), do: false

  defp selected_lines(calls, group) do
    Enum.reduce_while(calls, MapSet.new(), fn call, selected ->
      case select_clause(call.args, group) do
        {:ok, line} -> {:cont, MapSet.put(selected, line)}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp select_clause(args, group) do
    Enum.reduce_while(group, :unknown, fn clause, :unknown ->
      case match_head(clause.head, args) do
        :match -> {:halt, {:ok, clause.line}}
        :nomatch -> {:cont, :unknown}
        :unknown -> {:halt, :unknown}
      end
    end)
    |> case do
      {:ok, line} -> {:ok, line}
      :unknown -> :unknown
    end
  end

  defp match_head({:when, _, [head, guard]}, args) do
    case match_head(head, args) do
      :match -> eval_guard(guard, bindings(head, args))
      other -> other
    end
  end

  defp match_head({_name, _, args}, call) when is_atom(args) and call == [], do: :match

  defp match_head({_name, _, patterns}, call)
       when is_list(patterns) and length(patterns) == length(call) do
    Enum.reduce_while(Enum.zip(patterns, call), :match, fn {pattern, arg}, :match ->
      case match_arg(pattern, arg) do
        :match -> {:cont, :match}
        other -> {:halt, other}
      end
    end)
  end

  defp match_head(_, _), do: :unknown

  defp match_arg({:_, _, _}, _), do: :match
  defp match_arg({name, _, ctx}, _) when is_atom(name) and is_atom(ctx), do: :match

  defp match_arg(value, value) when is_atom(value) or is_number(value) or is_binary(value),
    do: :match

  defp match_arg(value, other) when is_atom(value) or is_number(value) or is_binary(value),
    do: (value == other && :match) || :nomatch

  defp match_arg([], []), do: :match
  defp match_arg([], _), do: :nomatch
  defp match_arg(_, _), do: :unknown

  defp bindings({:when, _, [head, _]}, args), do: bindings(head, args)

  defp bindings({_name, _, patterns}, args)
       when is_list(patterns) and length(patterns) == length(args) do
    Enum.reduce(Enum.zip(patterns, args), %{}, fn
      {{name, _, ctx}, value}, env when is_atom(name) and is_atom(ctx) and name != :_ ->
        Map.put(env, name, value)

      _, env ->
        env
    end)
  end

  defp bindings(_, _), do: %{}

  defp eval_guard({:and, _, [left, right]}, env) do
    combine(eval_guard(left, env), eval_guard(right, env), :and)
  end

  defp eval_guard({:or, _, [left, right]}, env) do
    combine(eval_guard(left, env), eval_guard(right, env), :or)
  end

  defp eval_guard({:not, _, [guard]}, env) do
    case eval_guard(guard, env) do
      :match -> :nomatch
      :nomatch -> :match
      :unknown -> :unknown
    end
  end

  defp eval_guard({:is_integer, _, [var]}, env), do: pred(env, var, &is_integer/1)
  defp eval_guard({:is_binary, _, [var]}, env), do: pred(env, var, &is_binary/1)
  defp eval_guard({:is_atom, _, [var]}, env), do: pred(env, var, &is_atom/1)
  defp eval_guard({:is_list, _, [var]}, env), do: pred(env, var, &is_list/1)
  defp eval_guard({:is_map, _, [var]}, env), do: pred(env, var, &is_map/1)
  defp eval_guard({:is_float, _, [var]}, env), do: pred(env, var, &is_float/1)
  defp eval_guard({:is_number, _, [var]}, env), do: pred(env, var, &is_number/1)
  defp eval_guard({:is_boolean, _, [var]}, env), do: pred(env, var, &is_boolean/1)
  defp eval_guard({:is_tuple, _, [var]}, env), do: pred(env, var, &is_tuple/1)
  defp eval_guard({:==, _, [left, right]}, env), do: compare(env, left, right, &==/2)
  defp eval_guard({:>, _, [left, right]}, env), do: compare(env, left, right, &>/2)
  defp eval_guard({:>=, _, [left, right]}, env), do: compare(env, left, right, &>=/2)
  defp eval_guard({:<, _, [left, right]}, env), do: compare(env, left, right, &</2)
  defp eval_guard({:<=, _, [left, right]}, env), do: compare(env, left, right, &<=/2)

  defp eval_guard({:in, _, [var, values]}, env) when is_list(values) do
    case env_value(env, var) do
      {:ok, value} -> if value in values, do: :match, else: :nomatch
      :error -> :unknown
    end
  end

  defp eval_guard(_, _), do: :unknown

  defp combine(:unknown, _, _), do: :unknown
  defp combine(_, :unknown, _), do: :unknown
  defp combine(:match, :match, :and), do: :match
  defp combine(_, _, :and), do: :nomatch
  defp combine(:nomatch, :nomatch, :or), do: :nomatch
  defp combine(_, _, :or), do: :match

  defp pred(env, var, fun) do
    case env_value(env, var) do
      {:ok, value} -> if fun.(value), do: :match, else: :nomatch
      :error -> :unknown
    end
  end

  defp compare(env, left, right, fun) do
    with {:ok, left} <- value_of(env, left), {:ok, right} <- value_of(env, right) do
      if fun.(left, right), do: :match, else: :nomatch
    else
      _ -> :unknown
    end
  end

  defp value_of(_env, value) when is_atom(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp value_of(env, var), do: env_value(env, var)

  defp env_value(env, {name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    Map.fetch(env, name)
  end

  defp env_value(_, _), do: :error

  defp clause_finding(clause, name, arity) do
    rel = relative(clause.file)

    message =
      "#{rel}:#{clause.line}: #{inspect(clause.mod)}.#{name}/#{arity} clause is never used. #{@fix}"

    %{sort: {rel, clause.line}, file: clause.file, line: clause.line, message: message}
  end

  defp compiler_findings(%{result: {:ok, _modules, warnings}}), do: warning_findings(warnings)

  defp compiler_findings(%{result: {:error, errors, warnings}}),
    do: warning_findings(warnings) ++ diagnostic_findings(errors, "compile error")

  defp warning_findings(%{compile_warnings: warnings}),
    do: diagnostic_findings(warnings, "compiler warning")

  defp warning_findings(_), do: []

  defp diagnostic_findings(diagnostics, kind) do
    Enum.map(diagnostics, fn diag ->
      file = diag_file(diag)
      line = diag_line(diag)
      rel = relative(file)
      text = diag_message(diag)

      message =
        if dead_compiler_warning?(text) do
          "#{rel}:#{line}: #{text} #{@fix}"
        else
          "#{rel}:#{line}: #{kind}: #{text} #{@fix}"
        end

      %{sort: {rel, line}, file: file, line: line, message: message}
    end)
  end

  defp dead_compiler_warning?(text) do
    String.contains?(text, "is unused") or String.contains?(text, "is never used") or
      String.contains?(text, "cannot match") or
      String.contains?(text, "default values for the optional arguments")
  end

  defp diag_file(%{file: file}) when is_binary(file), do: file
  defp diag_file(%{file: file}) when is_list(file), do: List.to_string(file)
  defp diag_file(_), do: "lib"

  defp diag_line(%{position: line}) when is_integer(line), do: line
  defp diag_line(%{position: {line, _col}}) when is_integer(line), do: line
  defp diag_line(%{position: position}) when is_list(position), do: position[:line] || 1
  defp diag_line(_), do: 1

  defp diag_message(%{message: message}) when is_binary(message), do: message
  defp diag_message(diag), do: inspect(diag)

  defp export_findings(dest, ctx) do
    lines =
      Map.new(ctx.clauses, fn clause ->
        {{clause.mod, clause.name, clause.arity}, {clause.file, clause.line}}
      end)

    name = :selective_dead_code_xref

    case :xref.start(name) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :xref.stop(name)
        {:ok, _pid} = :xref.start(name)
    end

    :xref.set_default(name, [{:warnings, false}])
    {:ok, _} = :xref.add_directory(name, String.to_charlist(dest), [{:warnings, false}])

    try do
      dest
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.flat_map(&unused_exports(&1, name, lines))
    after
      :xref.stop(name)
    end
  end

  defp unused_exports(beam, xref, lines) do
    charlist = String.to_charlist(beam)
    {:ok, {mod, chunks}} = :beam_lib.chunks(charlist, [:attributes, :exports])
    attributes = chunks[:attributes] || []
    callbacks = behaviour_callbacks(attributes)

    for {fun, arity} <- chunks[:exports] || [],
        not ignored_export?(fun, arity, callbacks),
        unused?(xref, {mod, fun, arity}) do
      {file, line} = Map.get(lines, {mod, fun, arity}, {beam, 1})
      rel = relative(file)

      message =
        "#{rel}:#{line}: #{inspect(mod)}.#{fun}/#{arity} has no caller in lib/. Tests do not count. #{@fix}"

      %{sort: {rel, line}, file: file, line: line, message: message}
    end
  end

  defp behaviour_callbacks(attributes) do
    attributes
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.flat_map(fn behaviour ->
      if function_exported?(behaviour, :behaviour_info, 1) do
        behaviour.behaviour_info(:callbacks) ++ behaviour.behaviour_info(:optional_callbacks)
      else
        []
      end
    end)
  end

  defp ignored_export?(fun, _arity, _callbacks) when fun in [:__info__, :module_info], do: true
  defp ignored_export?(:child_spec, 1, _callbacks), do: true
  defp ignored_export?(fun, arity, callbacks), do: {fun, arity} in callbacks

  defp unused?(xref, mfa) do
    {:ok, users} = :xref.analyze(xref, {:use, mfa})
    Enum.reject(users, &(&1 == mfa)) == []
  end

  defp allowed?(%{file: file, line: line}) when is_binary(file) and is_integer(line) do
    case File.read(file) do
      {:ok, source} ->
        source
        |> String.split("\n")
        |> Enum.at(line - 1, "")
        |> allow_marker?()

      _ ->
        false
    end
  end

  defp allowed?(_), do: false

  defp allow_marker?(line) do
    Regex.match?(
      ~r/#\s*dead-code-allow:\s*\S.+\sexpires:\s*\d{4}-\d{2}-\d{2}\s+approved:\s*\S+\s*$/,
      line
    )
  end

  defp walk({:defmodule, _, [alias_ast, [do: body]]}, ctx) do
    walk(body, %{ctx | mod: expand_alias(alias_ast, ctx), aliases: %{}})
  end

  defp walk({:alias, _, [{:__aliases__, _, parts}]}, ctx) do
    %{ctx | aliases: Map.put(ctx.aliases, List.last(parts), Module.concat(parts))}
  end

  defp walk({kind, meta, [head, body]}, ctx) when kind in [:def, :defp] and is_list(body) do
    ctx = record_clause(kind, meta, head, ctx)
    ctx = walk_defaults(head_args(head), ctx)
    walk(Keyword.get(body, :do), ctx)
  end

  defp walk({kind, meta, [head]}, ctx) when kind in [:def, :defp] do
    record_clause(kind, meta, head, ctx)
  end

  defp walk({:__block__, _, stmts}, ctx), do: walk(stmts, ctx)

  defp walk({{:., meta, [target, name]}, _meta, args}, ctx)
       when is_atom(name) and is_list(args) do
    ctx = record_remote(ctx, target, name, args, meta)
    ctx = walk(target, ctx)
    walk(args, ctx)
  end

  defp walk({name, meta, args}, ctx)
       when is_atom(name) and is_list(args) and name not in @special do
    ctx = if ctx.mod, do: record_call(ctx, ctx.mod, name, args, meta), else: ctx
    walk(args, ctx)
  end

  defp walk(list, ctx) when is_list(list), do: Enum.reduce(list, ctx, &walk/2)
  defp walk({left, right}, ctx), do: walk(right, walk(left, ctx))
  defp walk(tuple, ctx) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> walk(ctx)
  defp walk(_other, ctx), do: ctx

  defp record_clause(kind, meta, head, ctx) do
    {name, arity} = signature(head)

    clause = %{
      mod: ctx.mod,
      name: name,
      arity: arity,
      line: meta[:line] || 1,
      file: ctx.file,
      head: head,
      kind: kind
    }

    %{ctx | clauses: [clause | ctx.clauses]}
  end

  defp record_remote(ctx, :httpc, :request, args, meta) do
    if download_get?(ctx.file, args) do
      ctx
    else
      line = meta[:line] || 1
      rel = relative(ctx.file)

      message =
        "#{rel}:#{line}: :httpc.request is an in-VM fragment upload built for a later slice (review finding 1). #{@fix} The caller in this slice is transport --upload-fragment."

      finding = %{sort: {rel, line}, file: ctx.file, line: line, message: message}
      %{ctx | uploads: [finding | ctx.uploads]}
    end
  end

  defp record_remote(ctx, target, name, args, meta) do
    case resolve_target(target, ctx) do
      nil -> ctx
      mod -> record_call(ctx, mod, name, args, meta)
    end
  end

  defp download_get?(file, [method | _]) do
    method == :get and String.ends_with?(to_string(file), "lib/selective_exunit/transport.ex")
  end

  defp download_get?(_, _), do: false

  defp record_call(ctx, mod, name, args, meta) do
    call = %{mod: mod, name: name, args: args, line: meta[:line], file: ctx.file}
    %{ctx | calls: [call | ctx.calls]}
  end

  defp resolve_target({:__aliases__, _, [single]}, ctx) when is_atom(single) do
    Map.get(ctx.aliases, single, Module.concat([single]))
  end

  defp resolve_target({:__aliases__, _, parts}, _ctx), do: Module.concat(parts)
  defp resolve_target({:__MODULE__, _, _}, ctx), do: ctx.mod
  defp resolve_target(atom, _ctx) when is_atom(atom), do: atom
  defp resolve_target(_, _), do: nil

  defp expand_alias({:__aliases__, _, parts}, ctx) do
    case parts do
      [single] when is_atom(single) -> Map.get(ctx.aliases, single, Module.concat(Elixir, single))
      _ -> Module.concat(parts)
    end
  end

  defp expand_alias(atom, _ctx) when is_atom(atom), do: atom

  defp walk_defaults(args, ctx) do
    Enum.reduce(args, ctx, fn
      {:\\, _, [_var, default]}, ctx -> walk(default, ctx)
      _, ctx -> ctx
    end)
  end

  defp head_args({:when, _, [head, _]}), do: head_args(head)
  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args(_), do: []

  defp signature({:when, _, [head, _]}), do: signature(head)
  defp signature({name, _, args}) when is_list(args), do: {name, length(args)}
  defp signature({name, _, _}), do: {name, 0}

  defp relative(path) do
    path = to_string(path)
    Path.relative_to(path, File.cwd!()) |> to_string()
  end
end
