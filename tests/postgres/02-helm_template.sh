#!/usr/bin/env bash
# helm_template: rendered manifests are accepted by the API server (CRD schema)
#
# Run on its own:  ./tests/postgres/02-helm_template.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# helm lint does not check values against the CRD schema (the imagePullSecrets
# string-vs-object mistake passes lint). A server-side dry run does.
test_helm_template() {
  need helm; need kubectl
  local out; out=$(mktemp); trap "rm -f '$out'" EXIT
  helm template "$CLUSTER" "$CHART_DIR" -n "$NS" >"$out" || fail "helm template failed"
  ok "chart renders ($(grep -c '^kind:' "$out") objects)"
  k apply --dry-run=server --server-side --force-conflicts --field-manager=ci-dry-run -f "$out" \
    || fail "API server rejected the rendered manifests"
  ok "API server accepts the rendered manifests (dry run, nothing changed)"
}

run test_helm_template helm_template
