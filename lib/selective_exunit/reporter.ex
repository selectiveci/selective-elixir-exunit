defmodule SelectiveExunit.Reporter do
  alias SelectiveExunit.JSON
  alias SelectiveExunit.Results
  alias SelectiveExunit.TransportPort
  alias SelectiveExunit.UTF8

  def emit_attempt(tests, module_state, failure_count, test_case) do
    %{attempt: attempt} = Results.current()
    status = combined_status(tests, module_state, failure_count)
    fields = attempt_fields(test_case, tests, status, module_state)
    write_result(test_case.id, status, fields, attempt)
  end

  def emit_uncollected(id) do
    %{attempt: attempt} = Results.current()
    write_result(id, "failed", bare_fields(id, "failed", ["test was not collected"]), attempt)
  end

  defp write_result(id, status, fields, attempt) do
    payload = %{"type" => "test_case_result", "data" => Map.put(fields, "id", id)}

    case TransportPort.write(JSON.encode(payload)) do
      :ok ->
        Results.put(id, status, fields, attempt)

      {:error, :lost} ->
        Results.mark_lost()
    end
  end

  defp combined_status(tests, module_state, failure_count) do
    cond do
      failure_count > 0 or match?({:failed, _}, module_state) or Enum.any?(tests, &failed_test?/1) ->
        "failed"

      tests != [] and Enum.all?(tests, &pending_test?/1) ->
        "pending"

      true ->
        "passed"
    end
  end

  defp failed_test?(%{state: {:failed, _}}), do: true
  defp failed_test?(%{state: {:invalid, _}}), do: true
  defp failed_test?(_test), do: false

  defp pending_test?(%{state: {:skipped, _}}), do: true
  defp pending_test?(%{state: {:excluded, _}}), do: true
  defp pending_test?(_test), do: false

  defp attempt_fields(test_case, [], status, module_state) do
    bare_fields(test_case.id, status, UTF8.scrub_list(hook_lines(module_state, ["test failed"])))
  end

  defp attempt_fields(test_case, tests, status, module_state) do
    test = Enum.find(tests, &failed_test?/1) || hd(tests)
    time = Enum.sum(for item <- tests, do: item.time || 0)
    base = case_fields(test_case, status, test, time)

    if status == "failed" do
      Map.merge(base, %{
        "failure_message_lines" => UTF8.scrub_list(attempt_lines(tests, module_state)),
        "failure_formatted_backtrace" =>
          UTF8.scrub_list(attempt_trace(test, tests, module_state, test_case))
      })
    else
      base
    end
  end

  defp bare_fields(id, status, lines) do
    %{
      "description" => id,
      "full_description" => id,
      "status" => status,
      "file_path" => "",
      "line_number" => 0,
      "run_time" => 0.0,
      "pending_message" => :null,
      "failure_message_lines" => lines,
      "failure_formatted_backtrace" => []
    }
  end

  defp attempt_lines(tests, module_state) do
    from_tests =
      tests
      |> Enum.filter(&failed_test?/1)
      |> Enum.flat_map(&lines_for/1)

    case from_tests ++ hook_lines(module_state, []) do
      [] -> ["test failed"]
      lines -> lines
    end
  end

  defp lines_for(test) do
    lines = failure_lines(test)

    case Map.get(test, :parameters) do
      params when is_map(params) and map_size(params) > 0 ->
        lines ++ ["Parameters: #{inspect(params)}"]

      _ ->
        lines
    end
  end

  defp hook_lines({:failed, failures}, _fallback) when is_list(failures) do
    Enum.flat_map(failures, &failure_banner/1)
  end

  defp hook_lines(_state, fallback), do: fallback

  defp attempt_trace(test, tests, module_state, test_case) do
    case Enum.find(tests, &failed_test?/1) do
      nil -> with_location(frames(module_state), test, test_case)
      failed -> with_location(frames(failed.state), failed, test_case)
    end
  end

  defp with_location(frames, test, test_case) do
    if Enum.any?(frames, &String.contains?(&1, test_case.file_path)) do
      frames
    else
      frames ++ ["#{test_case.file_path}:#{test_case.line_number}: #{test.name}"]
    end
  end

  defp case_fields(test_case, status, test, time) do
    %{
      "description" => test_case.description,
      "full_description" => test_case.full_description,
      "status" => status,
      "file_path" => test_case.file_path,
      "line_number" => test_case.line_number,
      "run_time" => run_time(%{time: time}),
      "pending_message" => pending_message(test.state, status)
    }
  end

  defp run_time(test) do
    case test.time do
      us when is_integer(us) -> us / 1_000_000
      _ -> 0.0
    end
  end

  defp pending_message({:skipped, message}, "pending"), do: skip_text(message)
  defp pending_message({:excluded, message}, "pending"), do: skip_text(message)
  defp pending_message(_, _), do: :null

  defp skip_text(true), do: "skipped"
  defp skip_text(message) when is_binary(message), do: UTF8.scrub(message)
  defp skip_text(message) when is_atom(message), do: Atom.to_string(message)
  defp skip_text(message), do: UTF8.scrub(inspect(message))

  defp failure_lines(%{state: {:failed, failures}}),
    do: Enum.flat_map(failures, &failure_banner/1)

  defp failure_lines(%{state: {:invalid, module}}) do
    ["invalid test in #{inspect(invalid_name(module))}"]
  end

  defp invalid_name(%{name: name}), do: name
  defp invalid_name(module), do: module

  defp failure_banner({kind, reason, _stack}) do
    kind |> Exception.format_banner(reason) |> String.trim() |> String.split("\n")
  end

  defp frames({:failed, failures}) when is_list(failures) do
    failures
    |> Enum.flat_map(fn {_kind, _reason, stack} ->
      stack
      |> Exception.format_stacktrace()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp frames(_state), do: []
end
