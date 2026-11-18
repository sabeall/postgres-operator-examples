#!/usr/bin/env bash
# connect_pgbouncer: app user logs in through the pgBouncer Service
#
# Run on its own:  ./tests/postgres/10-connect_pgbouncer.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_connect_pgbouncer() {
  need_cluster
  [ -n "$(pgc '{.spec.proxy.pgBouncer}')" ] || skip "pgBouncer not enabled"
  local host port row
  host=$(secret_key pgbouncer-host); port=$(secret_key pgbouncer-port)
  [ -n "$host" ] || fail "secret $USER_SECRET has no pgbouncer-host"
  echo "connecting as $(secret_key user) to $host:$port/$(secret_key dbname)"
  row=$(remote_psql "$host" "$port" "select current_user, pg_is_in_recovery()") \
    || fail "could not connect through pgBouncer"
  echo "result: $row"
  [ "${row%%|*}" = "$(secret_key user)" ] || fail "unexpected user ${row%%|*}"
  [ "${row##*|}" = f ] || fail "pgBouncer routed to a replica"
  ok "connected through pgBouncer"
}

run test_connect_pgbouncer connect_pgbouncer
