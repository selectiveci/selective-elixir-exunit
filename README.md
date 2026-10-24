# selective-elixir-exunit

Selective client for ExUnit. `mix selective.test` loads the suite once, then runs each id the server assigns with `ExUnit.configure(only_test_ids: MapSet.new([{Module, :name}]))` and `ExUnit.run/1`. The socket is an Erlang Port to `transport --stdio`. This package is not published to Hex.

## Run

On first use, `mix selective.test` downloads the pinned [transport](https://github.com/selectiveci/transport) release asset for this host (the static Linux binary, or macOS), checks its sha256, and keeps it under `_build/`. `SELECTIVE_TRANSPORT` points at a binary instead. The pinned release (`v0.1.2`) has no `--stdio` mode yet, so until the next transport release the client refuses it and you build one:

```sh
git clone https://github.com/selectiveci/transport.git
git -C transport checkout 44a9c7abde5a35d869c5f71780d56e26c0c6f8bd
cargo build --release --locked --manifest-path transport/Cargo.toml
export SELECTIVE_TRANSPORT="$PWD/transport/target/release/transport"
```

On CI, `mix selective.test` replaces `mix test`. It runs the project's `test` alias steps first (Phoenix's `ecto.create` and `ecto.migrate`) and applies `mix test`'s selection, run and build flags: paths, `file:line`, `--include`, `--exclude`, `--only`, `--name-pattern`, `--failed`, `--seed`, `--timeout`, `--trace`, `--exit-status`, `--color`, `--formatter`, `--slowest`, `--warnings-as-errors`, `--no-compile`, `--no-start` and the other compile checks. A failure exits 2, like `mix test`. A `mix test` flag it cannot honor (`--cover`, `--stale`, `--partitions`, `--max-cases`, `--max-failures`, `--repeat-until-failure`, `--raise`, and the interactive ones) exits 1 naming the flag. The host project selects the test env:

```elixir
def cli do
  [preferred_envs: ["selective.test": :test]]
end
```

 `SELECTIVE_API_KEY` and `SELECTIVE_HOST` (or a detected CI environment) turn the connection on. The URL and the key are passed to the Port through `SELECTIVE_TRANSPORT_URL`, not on the command line. A missing binary exits 1.

Without a Selective key, host, or CI marker, the task runs `mix test` in this VM with the arguments untouched. It is not aliased over `mix test`, so that fallback does not call itself.

`SELECTIVE_TEST_MAP_DISABLE=1` advertises `test_map=0` and skips the git snapshot. Otherwise the client advertises `record`, or `select` while `:cover` is already running. When the server sends `record: true`, the client cover-compiles the project's own modules (`Mix.Project.compile_path()`) and resets the counters before each test. A test's deps are its own file plus the sources of the modules it called; skipped and excluded tests have none. At close the fragment is gzipped and uploaded through `transport --upload-fragment`. `SELECTIVE_TEST_MAP_IGNORE` takes comma-separated path prefixes to leave out.

If `:cover` cannot start, a module has no debug info, or a test stops `:cover`, the client warns once, runs the tests normally and uploads nothing. Dependencies, umbrella siblings and compile-time uses (macros, structs) are not traced, and a background process's calls count toward whichever test is running.

## Tests

CI runs Elixir 1.17–1.20 on OTP 27, 28 and 29, the suite on Debian bookworm (glibc 2.36), and an OTP 26 check. `examples/internal` is the suite the session tests drive. `script/conformance.sh` runs transport's conformance suite (`transport-conformance`, built from the same transport commit) against `examples/internal/test/conformance_test.exs`. OTP 27 or later is required when Selective is configured.
