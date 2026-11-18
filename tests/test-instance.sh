#!/usr/bin/env bash
# Creates a throwaway PostgresCluster from helm/postgres in its own namespace,
# so the chart can be tested from a fresh install without touching pg1.
#
#   ./tests/test-instance.sh up             create it and wait until it is ready
#   ./tests/test-instance.sh down           delete it, its namespace and its S3 backups
#   ./tests/test-instance.sh run [args]     up, run tests/test-postgres.sh [args], down
#   ./tests/test-instance.sh status         show the test cluster's state
#
# `run` passes its arguments to the test runner (e.g. --junit report.xml) and
# exits with the tests' exit code. KEEP=1 skips the teardown so you can debug.
#
# Override any of these with environment variables.
set -euo pipefail

TEST_NS="${TEST_NS:-pg-test}"           # namespace for the test cluster (created and deleted)
CLUSTER="${CLUSTER:-pgtest}"            # Helm release and PostgresCluster name
TEST_REPLICAS="${TEST_REPLICAS:-2}"     # 2 so the replication test runs
SRC_NS="${SRC_NS:-crunchy-postgres}"    # where the secrets below are copied from
SRC_CLUSTER="${SRC_CLUSTER:-pg1}"       # S3 bucket/endpoint/region are read from its spec
PULL_SECRET="${PULL_SECRET:-crunchy-regcred}"
SRC_S3_SECRET="${SRC_S3_SECRET:-${SRC_CLUSTER}-pgbackrest-s3}"
GARAGE_SVC="${GARAGE_SVC:-objstore-garage}"       # in SRC_NS; used by `down` to delete backups
GARAGE_SECRET="${GARAGE_SECRET:-objstore-garage}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"   # seconds
KEEP="${KEEP:-0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${CHART_DIR:-$HERE/../helm/postgres}"
LABEL="postgres-operator-examples/test-instance=true"   # `down` only deletes namespaces with this

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k()   { kubectl -n "$TEST_NS" "$@"; }
pgc() { k get postgrescluster "$CLUSTER" -o "jsonpath=$1" 2>/dev/null; }
for t in kubectl helm python3; do command -v "$t" >/dev/null || die "missing required tool: $t"; done

[ "$TEST_NS" != "$SRC_NS" ] || die "TEST_NS must not be $SRC_NS"

# Copies a Secret between namespaces with only its name, type and data, so no
# owner references or Helm ownership come along. Values are never printed.
copy_secret() { # $1 source name  $2 target name
  kubectl -n "$SRC_NS" get secret "$1" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"),
                  "metadata": {"name": sys.argv[1]}, "data": s.get("data", {})}))' "$2" \
    | k apply -f - >/dev/null
  echo "copied secret $SRC_NS/$1 -> $TEST_NS/$2"
}

src_s3() { kubectl -n "$SRC_NS" get postgrescluster "$SRC_CLUSTER" -o "jsonpath={.spec.backups.pgbackrest.repos[?(@.s3)].s3.$1}"; }

up() {
  log "Namespace $TEST_NS"
  kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$TEST_NS" "$LABEL" --overwrite >/dev/null
  echo "ready (labelled ${LABEL%=*})"

  log "Secrets"
  copy_secret "$PULL_SECRET" "$PULL_SECRET"
  copy_secret "$SRC_S3_SECRET" "${CLUSTER}-pgbackrest-s3"

  local bucket endpoint region
  bucket=$(src_s3 bucket); endpoint=$(src_s3 endpoint); region=$(src_s3 region)
  [ -n "$bucket" ] && [ -n "$endpoint" ] || die "no S3 repo on $SRC_NS/$SRC_CLUSTER to copy bucket/endpoint from"

  # The chart's values.yaml is used as-is, with these overrides: a smaller
  # topology, this cluster's own S3 secret and bucket path (so its backups never
  # mix with pg1's), retention of 1, and no schedules (no CronJobs to clean up).
  log "Helm install $CLUSTER (chart $CHART_DIR)"
  local vals; vals=$(mktemp)
  cat >"$vals" <<EOF
instances:
  - name: pgha1
    replicas: ${TEST_REPLICAS}
    dataVolumeClaimSpec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
pgBouncerReplicas: 1
pgBackRestConfig:
  configuration:
    - secret:
        name: ${CLUSTER}-pgbackrest-s3
  global:
    repo1-retention-full: "1"
    repo2-path: /pgbackrest/${TEST_NS}/${CLUSTER}/repo2
    repo2-s3-uri-style: path
    repo2-storage-verify-tls: "n"
    repo2-retention-full: "1"
  repos:
    - name: repo1
      volume:
        volumeClaimSpec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
    - name: repo2
      s3:
        bucket: ${bucket}
        endpoint: ${endpoint}
        region: ${region:-garage}
EOF
  echo "S3 repo2: bucket $bucket at $endpoint, path /pgbackrest/${TEST_NS}/${CLUSTER}/repo2"
  helm upgrade --install "$CLUSTER" "$CHART_DIR" -n "$TEST_NS" -f "$vals" >/dev/null || { rm -f "$vals"; die "helm install failed"; }
  rm -f "$vals"
  echo "release $CLUSTER installed"

  wait_ready
}

# Ready means: every instance and pgBouncer ready, a stanza on both repos, and
# the operator's initial backup to repo1 finished (the backups test needs one).
wait_ready() {
  log "Waiting for $CLUSTER to be ready (up to ${READY_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + READY_TIMEOUT )) last=""
  while :; do
    local ready want bouncer stanzas backup state
    ready=$(pgc '{.status.instances[0].readyReplicas}'); want=$(pgc '{.status.instances[0].replicas}')
    bouncer=$(pgc '{.status.proxy.pgBouncer.readyReplicas}')
    stanzas=$(pgc '{range .status.pgbackrest.repos[*]}{.name}={.stanzaCreated}{" "}{end}')
    backup=$(pgc '{.status.pgbackrest.repos[?(@.name=="repo1")].replicaCreateBackupComplete}')
    state="instances ${ready:-0}/${want:-?}  pgbouncer ${bouncer:-0}/1  stanza ${stanzas:-none}  initial-backup ${backup:-pending}"
    [ "$state" != "$last" ] && echo "$(date +%T) $state" && last=$state
    if [ -n "$want" ] && [ "${ready:-0}" = "$want" ] && [ "${bouncer:-0}" = 1 ] \
       && [ "$stanzas" = "repo1=true repo2=true " ] && [ "$backup" = true ]; then
      echo "ready"; return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "not ready after ${READY_TIMEOUT}s; pods and recent events:"
      k get pods -o wide || true
      k get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true
      return 1
    fi
    sleep 5
  done
}

down() {
  if ! kubectl get namespace "$TEST_NS" >/dev/null 2>&1; then
    echo "namespace $TEST_NS does not exist; nothing to do"
  else
    kubectl get namespace -l "$LABEL" -o name | grep -qx "namespace/$TEST_NS" \
      || die "namespace $TEST_NS was not created by this script (no $LABEL label); refusing to delete it"
    log "Uninstall $CLUSTER and delete namespace $TEST_NS"
    helm uninstall "$CLUSTER" -n "$TEST_NS" --wait >/dev/null 2>&1 || true
    kubectl delete namespace "$TEST_NS" --wait --timeout=300s
  fi
  delete_s3_backups
}

# Removes this cluster's repo2 path from the bucket. Runs an aws-cli pod in
# SRC_NS against Garage directly (single-object deletes do not work through the
# Caddy proxy; see scripts/README.md). The path always contains TEST_NS.
delete_s3_backups() {
  local bucket prefix
  bucket=$(src_s3 bucket)
  [ -n "$bucket" ] || { echo "no S3 bucket known; skipping S3 cleanup"; return 0; }
  prefix="pgbackrest/${TEST_NS}/${CLUSTER}/"
  log "Delete s3://$bucket/$prefix"
  local json
  json=$(python3 -c '
import json, sys
svc, secret, bucket, prefix = sys.argv[1:5]
cmd = ("aws --endpoint-url http://%s:3900 --region garage s3 rm --recursive --only-show-errors s3://%s/%s"
       " && echo removed" % (svc, bucket, prefix))
env = [{"name": n, "valueFrom": {"secretKeyRef": {"name": secret, "key": key}}}
       for n, key in (("AWS_ACCESS_KEY_ID", "access-key"), ("AWS_SECRET_ACCESS_KEY", "secret-key"))]
print(json.dumps({"spec": {"containers": [{"name": "awscli", "image": "amazon/aws-cli",
                                           "command": ["sh", "-c", cmd], "env": env}]}}))' \
    "$GARAGE_SVC" "$GARAGE_SECRET" "$bucket" "$prefix")
  kubectl -n "$SRC_NS" run "awscli-cleanup-$RANDOM" --rm -i --restart=Never --image=amazon/aws-cli \
    --overrides="$json" 2>&1 | grep -v -E 'If you don.t see a command prompt|^pod ".*" deleted' || true
}

status() {
  kubectl get namespace "$TEST_NS" >/dev/null 2>&1 || { echo "namespace $TEST_NS does not exist"; return 0; }
  k get postgrescluster,pods,pvc
  echo; k get postgrescluster "$CLUSTER" -o jsonpath='{.status.pgbackrest.repos}' 2>/dev/null; echo
}

run_tests() {
  local rc=0
  up || rc=$?
  if [ "$rc" = 0 ]; then
    log "Tests against $TEST_NS/$CLUSTER"
    NS="$TEST_NS" CLUSTER="$CLUSTER" CHART_DIR="$CHART_DIR" "$HERE/test-postgres.sh" "$@" || rc=$?
  fi
  if [ "$KEEP" = 1 ]; then
    log "KEEP=1: leaving $TEST_NS in place. Remove it with: $0 down"
  else
    down || true
  fi
  return "$rc"
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  run)    shift; run_tests "$@" ;;
  status) status ;;
  *)      sed -n '2,14p' "$0"; exit 1 ;;
esac
