#!/usr/bin/env bash
# replication: every replica is streaming from the primary
#
# Run on its own:  ./tests/postgres/08-replication.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_replication() {
  need_cluster
  local want primary got
  want=$(( $(total_instances) - 1 ))
  [ "$want" -gt 0 ] || skip "single instance, nothing to replicate"
  primary=$(primary_pod); [ -n "$primary" ] || fail "no primary"
  local_psql "$primary" "select application_name || ' ' || state || ' ' || sync_state || ' replay_lag=' || coalesce(replay_lag::text,'0') from pg_stat_replication" | sed 's/^/replica: /'
  got=$(local_psql "$primary" "select count(*) from pg_stat_replication where state = 'streaming'")
  [ "$got" = "$want" ] || fail "$got of $want replicas streaming"
  ok "$got of $want replicas streaming"
}

run test_replication replication
