defmodule SelectiveExunit.DriveTest do
  use ExUnit.Case, async: false

  alias SelectiveExunit.Test.Drive

  test "a session directory is not a leftover from another VM" do
    n = System.unique_integer([:positive])
    planted = Path.join(System.tmp_dir!(), "selective-exunit-#{n + 1}")
    File.rm_rf!(planted)
    File.mkdir_p!(planted)
    File.write!(Path.join(planted, "after"), "after\n")
    on_exit(fn -> File.rm_rf(planted) end)

    session = Drive.start()
    on_exit(fn -> File.rm_rf(session.dir) end)

    refute session.dir == planted
    assert Drive.lines(session, "after") == 0
  end
end
