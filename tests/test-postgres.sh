#!/usr/bin/env bash
# Runs the Postgres tests in tests/postgres/ and reports each one.
#
#   ./tests/test-postgres.sh                     run every test
#   ./tests/test-postgres.sh connect_primary ... run only the named tests
#   ./tests/test-postgres.sh --list              list the tests
#   ./tests/test-postgres.sh --junit out.xml     also write a JUnit report (for CI)
#
# Each test is its own script (tests/postgres/NN-name.sh) and can be run
# directly without this runner. The runner executes them in NN order, each in
# a separate process with a timeout, and prints a summary.
# Exit code: 0 if nothing failed, 1 otherwise (skips do not fail the run).
#
# Settings (NS, CLUSTER, CHART_DIR, ...) are environment variables; see
# tests/postgres/lib.sh. TEST_TIMEOUT (default 120s) applies to tests that do
# not declare their own "# timeout:" line.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/postgres" && pwd)"
source "$DIR/lib.sh"
set +u
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

name_of()     { basename "$1" .sh | sed 's/^[0-9]*-//'; }
timeout_for() { local t; t=$(sed -n 's/^# timeout: *\([0-9]*\).*/\1/p' "$1" | head -1); echo "${t:-$TEST_TIMEOUT}"; }

ALL=("$DIR"/[0-9]*.sh)
JUNIT=""; SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list)  for f in "${ALL[@]}"; do printf '%-20s %s\n' "$(name_of "$f")" "$(sed -n '2s/^# [a-z0-9_]*: //p' "$f")"; done; exit 0 ;;
    --junit) JUNIT="${2:?--junit needs a file}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *)       f=$(ls "$DIR"/[0-9]*-"$1".sh 2>/dev/null | head -1)
             [ -n "$f" ] || { echo "unknown test: $1 (see --list)" >&2; exit 2; }
             SELECTED+=("$f") ;;
  esac
  shift
done
[ ${#SELECTED[@]} -gt 0 ] || SELECTED=("${ALL[@]}")

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G= R= Y= B= N=; fi
now_ms() { date +%s%3N; }

echo "${B}Postgres tests${N}: cluster=$CLUSTER namespace=$NS chart=$CHART_DIR"
echo "context: $(kubectl config current-context 2>/dev/null || echo '?')  started: $(date -u +%FT%TZ)"
echo

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
declare -a R_NAME R_STATUS R_MS
pass=0 failn=0 skipn=0 suite_start=$(now_ms)

for f in "${SELECTED[@]}"; do
  t=$(name_of "$f")
  echo "${B}=== RUN   $t${N}  ($(basename "$f"))"
  start=$(now_ms)
  limit=$(timeout_for "$f")
  timeout "$limit" bash "$f" >"$WORK/$t.out" 2>&1
  rc=$?
  ms=$(( $(now_ms) - start ))
  [ "$rc" = 124 ] && echo "FAIL: timed out after ${limit}s" >>"$WORK/$t.out"
  # The script's own PASS line is redundant with the status line below.
  grep -v '^PASS: ' "$WORK/$t.out" | sed 's/^/    /'
  case "$rc" in
    0)     st=PASS; pass=$((pass + 1));  c=$G ;;
    "$SKIP") st=SKIP; skipn=$((skipn + 1)); c=$Y ;;
    *)     st=FAIL; failn=$((failn + 1)); c=$R
           [ "${GITHUB_ACTIONS:-}" = true ] && echo "::error title=postgres test $t::$(grep -m1 '^FAIL:' "$WORK/$t.out" || echo "exit $rc")" ;;
  esac
  printf -- '%s--- %s: %s (%d.%03ds)%s\n\n' "$c" "$st" "$t" $((ms / 1000)) $((ms % 1000)) "$N"
  R_NAME+=("$t"); R_STATUS+=("$st"); R_MS+=("$ms")
done

total_ms=$(( $(now_ms) - suite_start ))
echo "${B}================ SUMMARY ================${N}"
for i in "${!R_NAME[@]}"; do
  case "${R_STATUS[$i]}" in PASS) c=$G ;; FAIL) c=$R ;; *) c=$Y ;; esac
  printf '  %s%-4s%s  %-20s %6d.%03ds\n' "$c" "${R_STATUS[$i]}" "$N" "${R_NAME[$i]}" $((R_MS[i] / 1000)) $((R_MS[i] % 1000))
done
echo "-----------------------------------------"
printf '  %d passed, %d failed, %d skipped (%d tests, %d.%ds)\n' "$pass" "$failn" "$skipn" "${#R_NAME[@]}" $((total_ms / 1000)) $((total_ms % 1000 / 100))

if [ -n "$JUNIT" ]; then
  esc() { tr -d '\000-\010\013\014\016-\037' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    printf '<testsuites><testsuite name="postgres-%s" tests="%d" failures="%d" skipped="%d" time="%d.%03d">\n' \
      "$CLUSTER" "${#R_NAME[@]}" "$failn" "$skipn" $((total_ms / 1000)) $((total_ms % 1000))
    for i in "${!R_NAME[@]}"; do
      n=${R_NAME[$i]}
      printf '  <testcase classname="postgres.%s" name="%s" time="%d.%03d">\n' "$CLUSTER" "$n" $((R_MS[i] / 1000)) $((R_MS[i] % 1000))
      case "${R_STATUS[$i]}" in
        FAIL) printf '    <failure message="%s"/>\n' "$( (grep -m1 '^FAIL:' "$WORK/$n.out" || echo failed) | esc)" ;;
        SKIP) printf '    <skipped message="%s"/>\n' "$( (grep -m1 '^SKIP:' "$WORK/$n.out" || echo skipped) | esc)" ;;
      esac
      printf '    <system-out>%s</system-out>\n  </testcase>\n' "$(esc <"$WORK/$n.out")"
    done
    echo '</testsuite></testsuites>'
  } >"$JUNIT"
  echo "  JUnit report: $JUNIT"
fi

[ "$failn" = 0 ]
