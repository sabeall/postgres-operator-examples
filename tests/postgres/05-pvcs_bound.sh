#!/usr/bin/env bash
# pvcs_bound: data and backup repo PVCs exist and are Bound
#
# Run on its own:  ./tests/postgres/05-pvcs_bound.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_pvcs_bound() {
  need_cluster
  local name phase role repo bad=0 n_data=0
  while read -r name phase role repo; do
    [ -n "$name" ] || continue
    echo "$name: $phase"
    [ "$phase" = "Bound" ] || bad=1
    [ "$role" = "pgdata" ] && n_data=$((n_data + 1))
  done < <(k get pvc -l "postgres-operator.crunchydata.com/cluster=${CLUSTER}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.metadata.labels.postgres-operator\.crunchydata\.com/role}{" "}{.metadata.labels.postgres-operator\.crunchydata\.com/pgbackrest-repo}{"\n"}{end}')

  local want; want=$(total_instances)
  [ "$n_data" = "$want" ] || { echo "pgdata PVCs: found $n_data, expected $want"; bad=1; }
  # Every volume-backed pgBackRest repo in the spec needs its PVC.
  for repo in $(pgc '{range .spec.backups.pgbackrest.repos[?(@.volume)]}{.name}{" "}{end}'); do
    phase=$(k get pvc -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/pgbackrest-repo=${repo}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [ "$phase" = "Bound" ] || { echo "backup repo $repo: PVC ${phase:-missing}"; bad=1; }
  done
  [ "$bad" = 0 ] || fail "PVCs are missing or not Bound"
  ok "all PVCs Bound ($n_data data volumes)"
}

run test_pvcs_bound pvcs_bound
