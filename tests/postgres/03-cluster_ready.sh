#!/usr/bin/env bash
# cluster_ready: PostgresCluster reports every instance and pgBouncer ready
#
# Run on its own:  ./tests/postgres/03-cluster_ready.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_cluster_ready() {
  need_cluster
  local line name want ready bad=0
  while read -r name want ready; do
    [ -n "$name" ] || continue
    echo "instance set $name: ${ready:-0}/$want ready"
    [ "${ready:-0}" = "$want" ] || bad=1
  done < <(pgc '{range .status.instances[*]}{.name}{" "}{.replicas}{" "}{.readyReplicas}{"\n"}{end}')
  [ -n "$(pgc '{.status.instances[*].name}')" ] || fail "cluster has no instance status yet"
  if [ -n "$(pgc '{.spec.proxy.pgBouncer}')" ]; then
    want=$(pgc '{.status.proxy.pgBouncer.replicas}'); ready=$(pgc '{.status.proxy.pgBouncer.readyReplicas}')
    echo "pgBouncer: ${ready:-0}/${want:-?} ready"
    [ -n "$want" ] && [ "${ready:-0}" = "$want" ] || bad=1
  fi
  [ "$bad" = 0 ] || fail "not everything is ready"
  ok "PostgresCluster $CLUSTER is ready"
}

run test_cluster_ready cluster_ready
