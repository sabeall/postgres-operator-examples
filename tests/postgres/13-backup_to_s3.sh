#!/usr/bin/env bash
# backup_to_s3: creates a table, backs up to the S3 repo, proves the table is in it
#
# Run on its own:  ./tests/postgres/13-backup_to_s3.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
# timeout: 900
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Creates a table, takes a full backup to the S3 repo, and
# proves the table is in it: the backup must end at or after the WAL position
# recorded once the table was committed (a restore of that backup replays up to
# its stop LSN). pgbackrest verify then re-reads the backup from S3 and checks
# every file's checksum. The table is dropped afterwards; the backup is kept and
# expires under the repo's normal retention.
test_backup_to_s3() {
  need_cluster; need python3
  local repo n repohost primary table marker before after label stop
  repo=$(pgc '{range .spec.backups.pgbackrest.repos[?(@.s3)]}{.name}{" "}{end}' | awk '{print $1}')
  [ -n "$repo" ] || fail "no S3 repo in spec.backups.pgbackrest.repos"
  n=${repo#repo}
  echo "S3 repo: $repo (bucket $(pgc "{.spec.backups.pgbackrest.repos[?(@.name==\"$repo\")].s3.bucket}") at $(pgc "{.spec.backups.pgbackrest.repos[?(@.name==\"$repo\")].s3.endpoint}"))"
  [ "$(pgc "{.status.pgbackrest.repos[?(@.name==\"$repo\")].stanzaCreated}")" = true ] \
    || fail "stanza not created on $repo"
  repohost=$(k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/data=pgbackrest" -o name | head -1 | sed 's|pod/||')
  [ -n "$repohost" ] || fail "no pgBackRest repo host pod"
  primary=$(primary_pod); [ -n "$primary" ] || fail "no primary"

  # Backup labels on this repo, with each backup's stop LSN.
  labels() {
    k exec "$repohost" -c pgbackrest -- pgbackrest info --stanza="$STANZA" --repo="$n" --output=json \
      | python3 -c '
import json, sys
for st in json.load(sys.stdin):
    for b in st.get("backup", []):
        print(b["label"], b["lsn"]["stop"])'
  }

  table="ci_s3_probe_$(date +%s)"
  # Created as postgres: since Postgres 15 ordinary users cannot create tables
  # in the public schema, and this test is about backups, not grants.
  local db; db=$(secret_key dbname)
  db_psql() { k exec "$primary" -c database -- psql -X -q -At -v ON_ERROR_STOP=1 -d "$db" -c "$1"; }
  trap "kubectl -n '$NS' exec '$primary' -c database -- psql -X -q -d '$db' -c 'drop table if exists $table' >/dev/null 2>&1" EXIT
  db_psql "create table $table (id int primary key, note text); insert into $table select g, 'row ' || g from generate_series(1, 1000) g;" \
    || fail "could not create $table"
  marker=$(db_psql "select pg_current_wal_lsn()")
  ok "created $db.$table (1000 rows); committed by LSN $marker"

  before=$(labels) || fail "pgbackrest info failed on $repo"
  echo "running: pgbackrest backup --stanza=$STANZA --repo=$n --type=full"
  k exec "$repohost" -c pgbackrest -- pgbackrest backup --stanza="$STANZA" --repo="$n" --type=full --log-level-console=info \
    | grep -E 'INFO: (backup command end|new backup label|full backup size)|ERROR|WARN' | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "backup to $repo failed"

  after=$(labels) || fail "pgbackrest info failed on $repo"
  read -r label stop < <(comm -13 <(echo "$before" | sort) <(echo "$after" | sort) | tail -1)
  [ -n "$label" ] || fail "backup finished but no new backup appears on $repo"
  ok "new backup $label on $repo, stop LSN $stop"

  [ "$(local_psql "$primary" "select '$stop'::pg_lsn >= '$marker'::pg_lsn")" = t ] \
    || fail "backup stops at $stop, before the table was committed ($marker)"
  ok "backup covers the table (stop LSN $stop >= $marker)"

  k exec "$repohost" -c pgbackrest -- pgbackrest repo-ls --stanza="$STANZA" --repo="$n" "backup/$STANZA/$label" \
    | grep -qx 'backup.manifest' || fail "backup.manifest for $label not found in S3"
  ok "backup.manifest for $label is in the bucket"

  k exec "$repohost" -c pgbackrest -- pgbackrest verify --stanza="$STANZA" --repo="$n" --set="$label" --log-level-console=info \
    | grep -E 'INFO: (verify command end|.*(invalid|missing|checksum))|ERROR' | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "pgbackrest verify reported problems with $label"
  ok "pgbackrest verify: every file in $label re-read from S3 and checksums match"
}

run test_backup_to_s3 backup_to_s3
