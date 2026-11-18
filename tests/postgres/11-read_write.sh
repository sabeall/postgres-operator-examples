#!/usr/bin/env bash
# read_write: app user can write and read back (temp table, nothing kept)
#
# Run on its own:  ./tests/postgres/11-read_write.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_read_write() {
  need_cluster
  local token got
  token="ci-$(date +%s)-$RANDOM"
  # A temp table lives only for this session, so nothing is left behind.
  got=$(remote_psql "$(secret_key host)" "$(secret_key port)" \
    "create temp table ci_probe (note text); insert into ci_probe values ('$token'); select note from ci_probe;") \
    || fail "write/read failed"
  [ "$got" = "$token" ] || fail "read back '$got', expected '$token'"
  ok "wrote and read back a row as $(secret_key user)"
}

run test_read_write read_write
