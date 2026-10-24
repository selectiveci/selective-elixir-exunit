defmodule SelectiveExunit.JSONTest do
  use ExUnit.Case, async: true

  alias SelectiveExunit.JSON

  test "encodes nil as null and decodes it as null" do
    encoded = JSON.encode(%{"pending_message" => nil, "ok" => true, "n" => 1})
    assert encoded =~ ~s("pending_message":null)
    assert JSON.decode(encoded) == %{"pending_message" => :null, "ok" => true, "n" => 1}
  end

  test "round trips a manifest case" do
    term = %{"id" => "M.test a", "run_time" => 0.0, "line_number" => 12}
    assert JSON.decode(JSON.encode(term)) == term
  end
end
