ExUnit.start(autorun: false, exclude: [:shared_helper, :conformance, :recording])

if System.get_env("SELECTIVE_COVER_TAKEN"), do: {:ok, _pid} = :cover.start()

ExUnit.after_suite(fn _stats ->
  if path = System.get_env("SELECTIVE_AFTER_SUITE_FILE") do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "after\n", [:append])
  end
end)
