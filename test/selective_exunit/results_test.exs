defmodule SelectiveExunit.ResultsTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Results

  setup do
    start_supervised!(%{id: Results, start: {Results, :start_link, []}})
    :ok
  end

  test "a later pending result does not replace a pass on the same attempt" do
    Results.begin_attempt("id")
    %{attempt: attempt} = Results.current()
    Results.put("id", "passed", %{}, attempt)
    Results.put("id", "pending", %{}, attempt)
    assert Results.framework_status() == 0
    assert Results.stats().skipped == 0
  end

  test "remove drops whatever failure is held when it is applied" do
    Results.begin_attempt("id")
    Results.put("id", "failed", %{}, 1)
    Results.remove_failed("id")
    refute Results.emitted?("id")

    Results.begin_attempt("id")
    Results.put("id", "failed", %{}, 2)
    Results.remove_failed("id")
    refute Results.emitted?("id")
    assert Results.framework_status() == 0
  end

  test "remove leaves a pass alone" do
    Results.begin_attempt("id")
    Results.put("id", "passed", %{}, 1)
    Results.remove_failed("id")
    assert Results.emitted?("id")
  end

  test "begin_attempt drops the previous result" do
    Results.begin_attempt("id")
    Results.put("id", "failed", %{}, 1)
    Results.begin_attempt("id")
    refute Results.emitted?("id")
    assert Results.framework_status() == 0
  end

  test "an unknown id is left alone" do
    Results.remove_failed("missing")
    assert Results.framework_status() == 0
  end
end
