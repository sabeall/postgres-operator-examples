#!/usr/bin/env bash
# Sets up Garage (S3-compatible object store) plus a Caddy TLS proxy in front of
# it, so pgBackRest (HTTPS-only) can use it as an S3 repo. Safe to re-run.
#
#   ./setup-garage-s3.sh up        install/upgrade Garage + Caddy, then verify
#   ./setup-garage-s3.sh test      verify only (keys, bucket, S3 over HTTP + HTTPS)
#   ./setup-garage-s3.sh secret    create the pgBackRest S3 secret for pg1
#   ./setup-garage-s3.sh snippet   print the pg1 values.yaml snippet
#   ./setup-garage-s3.sh down      uninstall both AND delete Garage's PVC (asks first)
#
# Override any of these with environment variables.
set -euo pipefail

NS="${NS:-crunchy-postgres}"
BUCKET="${BUCKET:-my-bucket}"
GARAGE_RELEASE="${GARAGE_RELEASE:-objstore}"
GARAGE_CHART="${GARAGE_CHART:-oci://ghcr.io/quenchworks/charts/garage}"
GARAGE_VERSION="${GARAGE_VERSION:-0.0.19}"
GARAGE_SIZE="${GARAGE_SIZE:-50G}"
CADDY_RELEASE="${CADDY_RELEASE:-my-caddy}"
CADDY_CHART="${CADDY_CHART:-oci://ghcr.io/quenchworks/charts/caddy}"
CADDY_VERSION="${CADDY_VERSION:-0.0.26}"
CADDY_CERT_DAYS="${CADDY_CERT_DAYS:-3650}"   # validity of the chart's self-signed cert
PG_CLUSTER="${PG_CLUSTER:-pg1}"
PGB_SECRET="${PGB_SECRET:-${PG_CLUSTER}-pgbackrest-s3}"
REPO="${REPO:-repo2}"            # which pgBackRest repo number the S3 store is

# Names derived from the charts' conventions (Helm release name + chart name).
GARAGE_SVC="${GARAGE_RELEASE}-garage"
GARAGE_POD="${GARAGE_RELEASE}-garage-0"
GARAGE_PVC="data-${GARAGE_RELEASE}-garage-0"
GARAGE_SECRET="${GARAGE_RELEASE}-garage"
CADDY_SVC="${CADDY_RELEASE}-caddy"
TLS_HOST="${CADDY_SVC}.${NS}.svc"

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k()   { kubectl -n "$NS" "$@"; }

need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }
need kubectl; need helm

# ------------------------------------------------------------------ garage ---
install_garage() {
  log "Garage"
  if ! helm status "$GARAGE_RELEASE" -n "$NS" >/dev/null 2>&1; then
    # A StatefulSet PVC survives `helm uninstall`. Reinstalling over it makes
    # Garage skip bootstrap ("already bootstrapped") while the chart generates
    # a NEW random key in the secret, so the secret and Garage disagree (403
    # "No such key"). Refuse to continue rather than create that mismatch.
    if k get pvc "$GARAGE_PVC" >/dev/null 2>&1; then
      die "PVC $GARAGE_PVC exists from an earlier install. Run '$0 down' first (this deletes its data), or delete the PVC yourself."
    fi
    helm install "$GARAGE_RELEASE" "$GARAGE_CHART" --version "$GARAGE_VERSION" -n "$NS" \
      --set config.defaultBucket="$BUCKET" \
      --set persistence.size="$GARAGE_SIZE"
  else
    echo "release $GARAGE_RELEASE already installed; leaving it alone"
  fi
  k rollout status "sts/${GARAGE_SVC}" --timeout=180s
}

# ------------------------------------------------------------------- caddy ---
# The chart's probes do GET / on :8080. Proxying that to Garage returns 403 and
# the pod crash-loops, so kubelet probes get a direct 200 and all else is proxied.
install_caddy() {
  log "Caddy TLS proxy"
  local vals; vals="$(mktemp)"; trap 'rm -f "$vals"' RETURN
  cat >"$vals" <<EOF
config:
  caddyfile: |
    {
    	admin :2019
    }
    :8080 {
    	@kubeprobe header User-Agent kube-probe*
    	handle @kubeprobe {
    		respond "ok" 200
    	}
    	handle {
    		reverse_proxy ${GARAGE_SVC}:3900
    	}
    }
tls:
  enabled: true
  selfSigned:
    validityDays: ${CADDY_CERT_DAYS}
service:
  httpsPort: 443
EOF
  helm upgrade --install "$CADDY_RELEASE" "$CADDY_CHART" --version "$CADDY_VERSION" \
    -n "$NS" -f "$vals"
  k rollout status "deploy/${CADDY_SVC}" --timeout=180s
}

# ------------------------------------------------------------------ verify ---
secret_val() { k get secret "$GARAGE_SECRET" -o "jsonpath={.data.$1}" | base64 -d; }

# Runs a throwaway aws-cli pod. Credentials come from the Garage secret via
# secretKeyRef, so they never appear on the command line or in the pod spec.
aws_pod() { # $1 = shell snippet to run
  local name="awscli-$RANDOM" json
  json=$(cat <<EOF
{"spec":{"containers":[{"name":"awscli","image":"amazon/aws-cli","command":["sh","-c",$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')],"env":[
{"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"${GARAGE_SECRET}","key":"access-key"}}},
{"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"${GARAGE_SECRET}","key":"secret-key"}}}]}]}}
EOF
)
  k run "$name" --rm -i --restart=Never --image=amazon/aws-cli --overrides="$json" 2>&1 \
    | grep -v -E 'If you don.t see a command prompt|^pod ".*" deleted|InsecureRequestWarning'
}

verify() {
  log "Secret vs Garage"
  local ak; ak="$(secret_val access-key)"
  k exec "$GARAGE_POD" -- garage key list | grep -q "$ak" \
    || die "key $ak from secret $GARAGE_SECRET is NOT in Garage (stale PVC?). Run '$0 down' then '$0 up'."
  echo "ok: access key from the secret exists in Garage"
  local h1 h2
  h1="$(secret_val secret-key | sha256sum | cut -c1-12)"
  h2="$(k exec "$GARAGE_POD" -- sh -c 'printf %s "$GARAGE_S3_SECRET_KEY" | sha256sum' | cut -c1-12)"
  [ "$h1" = "$h2" ] || die "secret-key in the Secret differs from the one Garage is running with"
  echo "ok: secret key matches the pod's"
  k exec "$GARAGE_POD" -- garage bucket list | grep -q "$BUCKET" || die "bucket $BUCKET not found"
  echo "ok: bucket $BUCKET exists"

  log "S3 over plain HTTP (direct to Garage)"
  aws_pod "E='--endpoint-url http://${GARAGE_SVC}:3900 --region garage'
    aws \$E s3 ls | grep -q ${BUCKET} && echo 'ok: list'
    echo direct > /tmp/t && aws \$E s3 cp /tmp/t s3://${BUCKET}/_setup_test >/dev/null && echo 'ok: put'
    aws \$E s3 cp s3://${BUCKET}/_setup_test - | grep -q direct && echo 'ok: get'
    aws \$E s3 rm s3://${BUCKET}/_setup_test >/dev/null && echo 'ok: delete'"

  log "S3 over HTTPS (through Caddy, cert not verified)"
  # NOTE: DELETE through Caddy is known to fail with Garage ("signed header
  # content-length is not present"; Go's proxy drops Content-Length: 0), so the
  # test object is removed directly against Garage instead.
  aws_pod "T='--endpoint-url https://${TLS_HOST} --region garage --no-verify-ssl'
    D='--endpoint-url http://${GARAGE_SVC}:3900 --region garage'
    aws \$T s3 ls | grep -q ${BUCKET} && echo 'ok: list'
    echo tls > /tmp/t && aws \$T s3 cp /tmp/t s3://${BUCKET}/_setup_test_tls >/dev/null && echo 'ok: put'
    aws \$T s3 cp s3://${BUCKET}/_setup_test_tls - | grep -q tls && echo 'ok: get'
    aws \$D s3 rm s3://${BUCKET}/_setup_test_tls >/dev/null && echo 'ok: cleanup (direct)'"
}

# --------------------------------------------------------------- pgbackrest ---
make_secret() {
  log "pgBackRest S3 secret ${PGB_SECRET}"
  local ak sk
  ak="$(secret_val access-key)"; sk="$(secret_val secret-key)"
  # pgBackRest reads keys from s3.conf in a Secret; the key prefix must match $REPO.
  k create secret generic "$PGB_SECRET" \
    --from-literal=s3.conf="[global]
${REPO}-s3-key=${ak}
${REPO}-s3-key-secret=${sk}" \
    --dry-run=client -o yaml | k apply -f -
}

snippet() {
  cat <<EOF

# Add to the ${PG_CLUSTER} chart's values.yaml (this REPLACES the chart's default backup block,
# so repo1 is restated). Then: helm upgrade ${PG_CLUSTER} <chart> -n ${NS}
pgBackRestConfig:
  configuration:
    - secret:
        name: ${PGB_SECRET}
  global:
    ${REPO}-path: /pgbackrest/${NS}/${PG_CLUSTER}/${REPO}
    ${REPO}-s3-uri-style: path
    ${REPO}-storage-verify-tls: "n"
    ${REPO}-retention-full: "7"
  repos:
    - name: repo1
      volume:
        volumeClaimSpec:
          accessModes: ["ReadWriteOnce"]
          resources: { requests: { storage: 1Gi } }
    - name: ${REPO}
      s3:
        bucket: ${BUCKET}
        endpoint: ${TLS_HOST}
        region: garage

# Check afterwards:
#   kubectl -n ${NS} exec ${PG_CLUSTER}-repo-host-0 -c pgbackrest -- pgbackrest info
EOF
}

# -------------------------------------------------------------------- down ---
down() {
  log "This uninstalls Garage and Caddy and DELETES the PVC $GARAGE_PVC (all stored objects)."
  read -r -p "Type the namespace ($NS) to confirm: " ans
  [ "$ans" = "$NS" ] || die "not confirmed"
  helm uninstall "$CADDY_RELEASE" -n "$NS" || true
  helm uninstall "$GARAGE_RELEASE" -n "$NS" || true
  k delete pvc "$GARAGE_PVC" --ignore-not-found
}

case "${1:-}" in
  up)      install_garage; install_caddy; verify; snippet ;;
  test)    verify ;;
  secret)  make_secret ;;
  snippet) snippet ;;
  down)    down ;;
  *)       sed -n '2,12p' "$0"; exit 1 ;;
esac
