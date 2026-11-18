#!/usr/bin/env bash
# backups: pgBackRest stanza exists, WAL archiving works, a backup exists
#
# Run on its own:  ./tests/postgres/12-backups.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_backups() {
  need_cluster
  local bad=0 name created primary row archived failed last_ok last_fail
  while read -r name created; do
    [ -n "$name" ] || continue
    echo "repo $name: stanzaCreated=${created:-false}"
    [ "$created" = true ] || bad=1
  done < <(pgc '{range .status.pgbackrest.repos[*]}{.name}{" "}{.stanzaCreated}{"\n"}{end}')

  primary=$(primary_pod); [ -n "$primary" ] || fail "no primary"
  row=$(local_psql "$primary" "select archived_count, failed_count, coalesce(last_archived_time::text,''), coalesce(last_failed_time::text,''), coalesce(last_archived_time > last_failed_time or last_failed_time is null, false) from pg_stat_archiver")
  IFS='|' read -r archived failed last_ok last_fail healthy <<<"$row"
  echo "WAL archiving: archived=$archived failed=$failed last_ok=${last_ok:-never} last_fail=${last_fail:-never}"
  if [ "$archived" = 0 ] || [ "$healthy" != t ]; then
    echo "archive-push log (tail) on $primary:"
    k exec "$primary" -c database -- sh -c 'tail -n 4 /pgdata/pgbackrest/log/*archive-push*.log 2>/dev/null' | sed 's/^/  /'
    bad=1
  fi

  local repohost; repohost=$(k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/data=pgbackrest" -o name | head -1 | sed 's|pod/||')
  if [ -n "$repohost" ]; then
    local info; info=$(k exec "$repohost" -c pgbackrest -- pgbackrest info --output=json 2>&1)
    # Judged per repo: "no valid backups" (code 2) is normal for a repo whose
    # first scheduled backup has not run yet, so it is reported but not failed.
    # Any other non-zero code fails, and at least one backup must exist.
    printf '%s' "$info" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("pgbackrest info output unreadable"); sys.exit(1)
if not s:
    print("no stanzas"); sys.exit(1)
bad, total = False, 0
for st in s:
    counts = {}
    for b in st.get("backup", []):
        key = b["database"]["repo-key"]; counts[key] = counts.get(key, 0) + 1
    total += len(st.get("backup", []))
    for r in st.get("repo", []):
        code, msg = r["status"]["code"], r["status"]["message"]
        note = "" if code in (0, 2) else "  <-- problem"
        print("stanza %s repo%s: %s, %d backup(s)%s" % (st["name"], r["key"], msg, counts.get(r["key"], 0), note))
        bad = bad or code not in (0, 2)
if total == 0:
    print("no backups in any repo"); bad = True
sys.exit(1 if bad else 0)' || bad=1
  fi
  [ "$bad" = 0 ] || fail "backups are not working"
  ok "stanza created, WAL archiving healthy, backups present"
}

run test_backups backups
