#!/usr/bin/env bash
# pods_running: expected pods exist, are Running and every container is ready
#
# Run on its own:  ./tests/postgres/04-pods_running.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_pods_running() {
  need_cluster
  local instances repohost=0 bouncer=0
  instances=$(total_instances)
  [ -n "$(pgc '{.status.pgbackrest.repoHost}')" ] && repohost=1
  if [ -n "$(pgc '{.spec.proxy.pgBouncer}')" ]; then
    bouncer=$(pgc '{.spec.proxy.pgBouncer.replicas}'); bouncer=${bouncer:-1}
  fi
  echo "expecting: $instances postgres, $repohost repo host, $bouncer pgbouncer"

  local name phase ready restarts bad=0 n_pg=0 n_repo=0 n_pgb=0 data role
  while read -r name phase ready restarts data role; do
    [ -n "$name" ] || continue
    # Finished backup/restore Job pods are expected to be Succeeded.
    [ "$phase" = "Succeeded" ] && continue
    if [ "$phase" != "Running" ] || [[ "$ready" == *false* ]]; then
      echo "NOT READY: $name phase=$phase containers-ready=${ready%,}"; bad=1
    else
      echo "running: $name (restarts ${restarts%,})"
    fi
    # Labels get a trailing "-" so an absent label is still a field.
    case "$data/$role" in
      postgres-/*)    n_pg=$((n_pg + 1)) ;;
      pgbackrest-/*)  n_repo=$((n_repo + 1)) ;;
      */pgbouncer-)   n_pgb=$((n_pgb + 1)) ;;
    esac
  done < <(k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.containerStatuses[*]}{.ready}{","}{end}{" "}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{" "}{.metadata.labels.postgres-operator\.crunchydata\.com/data}{"-"}{" "}{.metadata.labels.postgres-operator\.crunchydata\.com/role}{"-"}{"\n"}{end}')

  [ "$n_pg"  = "$instances" ] || { echo "postgres pods: found $n_pg, expected $instances"; bad=1; }
  [ "$n_repo" = "$repohost" ] || { echo "repo host pods: found $n_repo, expected $repohost"; bad=1; }
  [ "$n_pgb" = "$bouncer" ]   || { echo "pgbouncer pods: found $n_pgb, expected $bouncer"; bad=1; }
  [ "$bad" = 0 ] || fail "pods are missing or not ready"
  ok "all $((n_pg + n_repo + n_pgb)) pods running and ready"
}

run test_pods_running pods_running
