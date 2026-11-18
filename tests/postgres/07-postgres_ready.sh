#!/usr/bin/env bash
# postgres_ready: every instance accepts connections; roles are correct
#
# Run on its own:  ./tests/postgres/07-postgres_ready.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_postgres_ready() {
  need_cluster
  local pod primary pods bad=0 rec
  primary=$(primary_pod); pods=$(instance_pods)
  [ -n "$pods" ] || fail "no instance pods found"
  for pod in $pods; do
    if ! k exec "$pod" -c database -- pg_isready -q; then
      echo "$pod: not accepting connections"; bad=1; continue
    fi
    rec=$(local_psql "$pod" "select pg_is_in_recovery()") || { echo "$pod: query failed"; bad=1; continue; }
    if [ "$pod" = "$primary" ]; then
      [ "$rec" = f ] && echo "$pod: primary, read-write" || { echo "$pod: labelled primary but in recovery"; bad=1; }
    else
      [ "$rec" = t ] && echo "$pod: replica, in recovery" || { echo "$pod: labelled replica but not in recovery"; bad=1; }
    fi
  done
  [ "$bad" = 0 ] || fail "not every instance is healthy"
  echo "version: $(local_psql "${primary:-$(echo "$pods" | head -1)}" "select version()")"
  ok "all instances accept connections"
}

run test_postgres_ready postgres_ready
