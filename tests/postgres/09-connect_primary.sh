#!/usr/bin/env bash
# connect_primary: app user logs in over TCP + TLS through the primary Service
#
# Run on its own:  ./tests/postgres/09-connect_primary.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_connect_primary() {
  need_cluster
  local host port row
  host=$(secret_key host); port=$(secret_key port)
  [ -n "$host" ] || fail "secret $USER_SECRET has no host"
  echo "connecting as $(secret_key user) to $host:$port/$(secret_key dbname)"
  row=$(remote_psql "$host" "$port" "select current_user, current_database(), (select ssl from pg_stat_ssl where pid = pg_backend_pid()), pg_is_in_recovery()") \
    || fail "could not connect through $host"
  echo "result: $row"
  IFS='|' read -r user db ssl rec <<<"$row"
  [ "$user" = "$(secret_key user)" ] || fail "logged in as $user"
  [ "$ssl" = t ] || fail "connection is not using TLS"
  [ "$rec" = f ] || fail "primary Service routed to a replica"
  ok "connected to the primary over TLS"
}

run test_connect_primary connect_primary
