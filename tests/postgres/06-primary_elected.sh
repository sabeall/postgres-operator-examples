#!/usr/bin/env bash
# primary_elected: exactly one primary
#
# Run on its own:  ./tests/postgres/06-primary_elected.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_primary_elected() {
  need_cluster
  local primaries; primaries=$(primary_pod)
  echo "primary: ${primaries:-<none>}"
  [ -n "$primaries" ] || fail "no pod has role=master"
  [ "$(echo "$primaries" | wc -l)" = 1 ] || fail "more than one primary: $(echo $primaries)"
  ok "exactly one primary"
}

run test_primary_elected primary_elected
