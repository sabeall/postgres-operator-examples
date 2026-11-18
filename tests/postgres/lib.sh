# Shared settings and helpers for the scripts in this directory. Not a test;
# each NN-name.sh sources it. Override any setting with an environment variable.
NS="${NS:-crunchy-postgres}"
CLUSTER="${CLUSTER:-pg1}"
CHART_DIR="${CHART_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../helm/postgres" && pwd)}"
USER_SECRET="${USER_SECRET:-${CLUSTER}-pguser-${CLUSTER}}"
STANZA="${STANZA:-db}"

SKIP=77   # exit code a test uses to report "skipped"

set -uo pipefail

k()     { kubectl -n "$NS" "$@"; }
fail()  { echo "FAIL: $*"; exit 1; }
skip()  { echo "SKIP: $*"; exit "$SKIP"; }
ok()    { echo "ok: $*"; }
need()  { command -v "$1" >/dev/null || fail "required tool not found: $1"; }

pgc()   { k get postgrescluster "$CLUSTER" -o "jsonpath=$1"; }
need_cluster() {
  need kubectl
  k get postgrescluster "$CLUSTER" >/dev/null 2>&1 \
    || fail "PostgresCluster $CLUSTER not found in namespace $NS"
}

# Total Postgres instances across all instance sets (replicas defaults to 1).
total_instances() {
  local n=0 r
  for r in $(pgc '{range .spec.instances[*]}{.replicas}{"|"}{end}' | tr '|' ' '); do n=$((n + r)); done
  # An instance set without "replicas" renders as an empty field.
  local sets; sets=$(pgc '{range .spec.instances[*]}{.name}{" "}{end}' | wc -w)
  local with; with=$(pgc '{range .spec.instances[*]}{.replicas}{" "}{end}' | wc -w)
  echo $((n + sets - with))
}

instance_pods() { k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/data=postgres" -o name | sed 's|pod/||'; }
primary_pod()   { k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/role=master" -o name | sed 's|pod/||'; }

# Run SQL locally in an instance pod as the postgres superuser (unix socket).
local_psql() { k exec "$1" -c database -- psql -X -q -At -v ON_ERROR_STOP=1 -c "$2"; }

secret_key() { k get secret "$USER_SECRET" -o "jsonpath={.data.$1}" | base64 -d; }

# Run SQL as the app user over the network. The client is a replica pod when
# there is one, so the connection really crosses the pod network. The password
# goes in on stdin, so it never appears in a command line or the pod spec.
remote_psql() { # $1 host  $2 port  $3 sql
  k get secret "$USER_SECRET" >/dev/null 2>&1 || fail "user secret $USER_SECRET not found"
  local client user db
  client=$(k get pods -l "postgres-operator.crunchydata.com/cluster=${CLUSTER},postgres-operator.crunchydata.com/role=replica" -o name | head -1 | sed 's|pod/||')
  [ -n "$client" ] || client=$(primary_pod)
  [ -n "$client" ] || fail "no instance pod available to run psql from"
  user=$(secret_key user); db=$(secret_key dbname)
  secret_key password | k exec -i "$client" -c database -- sh -c '
    IFS= read -r PGPASSWORD || true; export PGPASSWORD
    exec psql -X -q -At -v ON_ERROR_STOP=1 \
      "host=$1 port=$2 user=$3 dbname=$4 sslmode=require connect_timeout=10" -c "$5"' \
    _ "$1" "$2" "$user" "$db" "$3"
}

# Run a test body and print its result line. fail/skip exit before this prints.
run() { "$1"; echo "PASS: ${2:-$1}"; }
