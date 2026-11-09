#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../examples/internal"
conformance=${TRANSPORT_CONFORMANCE:?path to transport-conformance}
transport=${SELECTIVE_TRANSPORT:?path to transport}
flake=$(mktemp)
status=0
for scenario in $("$conformance" list); do
  rm -f "$flake"
  output=$(SELECTIVE_FLAKE_FILE=$flake "$conformance" run --scenario "$scenario" \
    --client "mix selective.test test/conformance_test.exs --include conformance" \
    --fixture-ids conformance-ids.json --transport "$transport" 2>&1)
  if [ $? = 0 ]; then
    echo "$output" | grep -E "^(ok|n/a) "
  elif echo "$output" | grep -q "^$scenario client: $scenario: exit exit status: 2, expected 1$"; then
    echo "exit-2 $scenario: mix test's failure status; the scenario expects 1"
  elif echo "$output" | grep -qx "no conformance scenarios ran for --scenario $scenario"; then
    echo "$output" | grep -E "^n/a "
  else
    echo "$output"
    status=1
  fi
done
exit $status
