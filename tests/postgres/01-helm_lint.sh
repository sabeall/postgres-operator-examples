#!/usr/bin/env bash
# helm_lint: chart passes helm lint --strict
#
# Run on its own:  ./tests/postgres/01-helm_lint.sh
# Exit code: 0 pass, 1 fail, 77 skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ------------------------------------------------------------------- tests ---
test_helm_lint() {
  need helm
  [ -f "$CHART_DIR/Chart.yaml" ] || fail "no chart at $CHART_DIR"
  helm lint --strict "$CHART_DIR" || fail "helm lint reported errors"
  ok "helm lint --strict $CHART_DIR"
}

run test_helm_lint helm_lint
