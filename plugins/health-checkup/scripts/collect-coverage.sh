#!/usr/bin/env bash
# Tier C — unit-test coverage c0 / c1 / c2 (#3).
#
# Reads an existing coverage artifact; it never runs the test suite. Supported
# formats: lcov, Istanbul coverage-summary.json, Cobertura XML, JaCoCo XML.
#
# c2 (condition coverage) is reported as skipped unless HC_COVERAGE_C2 is set:
# none of the formats above emit it, and a branch percentage is not a condition
# percentage. Substituting c1 for c2 would quietly corrupt the trend.
#
# Usage:
#   collect-coverage.sh [--file PATH]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

while [ $# -gt 0 ]; do
  case "$1" in
    --file) HC_COVERAGE_FILE="$2"; shift 2 ;;
    *) printf 'collect-coverage.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

find_artifact() {
  [ -n "$HC_COVERAGE_FILE" ] && { printf '%s\n' "$HC_COVERAGE_FILE"; return; }
  local c
  for c in \
    coverage/lcov.info lcov.info coverage/lcov/lcov.info \
    coverage/coverage-summary.json \
    coverage/cobertura-coverage.xml coverage.xml coverage/coverage.xml \
    target/site/jacoco/jacoco.xml build/reports/jacoco/test/jacocoTestReport.xml
  do
    [ -f "$HC_ROOT/$c" ] && { printf '%s\n' "$HC_ROOT/$c"; return; }
  done
  return 0   # "not found" is a normal outcome, not a failure
}

ART="$(find_artifact)"
if [ -z "$ART" ] || [ ! -f "$ART" ]; then
  reason="coverage 成果物が見つからない（先に coverage を生成する / HC_COVERAGE_FILE で指定）"
  hc_skip "coverage.c0" "$reason"
  hc_skip "coverage.c1" "$reason"
  hc_skip "coverage.c2" "$reason"
  exit 0
fi

pct() { # pct <hit> <total>
  local hit="$1" total="$2"
  [ "${total:-0}" -gt 0 ] 2>/dev/null || return 1
  awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.0f%%", (h * 100) / t }'
}

c0=""; c1=""
case "$ART" in
  *.info)
    read -r lf lh brf brh <<< "$(awk -F: '
      /^LF:/  { lf  += $2 }
      /^LH:/  { lh  += $2 }
      /^BRF:/ { brf += $2 }
      /^BRH:/ { brh += $2 }
      END { print lf+0, lh+0, brf+0, brh+0 }' "$ART")"
    c0="$(pct "$lh" "$lf" || true)"
    c1="$(pct "$brh" "$brf" || true)"
    ;;
  *coverage-summary.json)
    if hc_have jq; then
      c0="$(jq -r '.total.lines.pct | if . == null then "" else "\(. | round)%" end' "$ART" 2>/dev/null || true)"
      c1="$(jq -r '.total.branches.pct | if . == null then "" else "\(. | round)%" end' "$ART" 2>/dev/null || true)"
    else
      c0="$(tr ',' '\n' < "$ART" | grep -A2 -m1 '"lines"' | grep -oE '"pct":[0-9.]+' | grep -oE '[0-9.]+' | awk 'NR==1{printf "%.0f%%", $1}' || true)"
      c1="$(tr ',' '\n' < "$ART" | grep -A2 -m1 '"branches"' | grep -oE '"pct":[0-9.]+' | grep -oE '[0-9.]+' | awk 'NR==1{printf "%.0f%%", $1}' || true)"
    fi
    ;;
  *.xml)
    if grep -q '<coverage[^>]*line-rate' "$ART"; then    # Cobertura
      c0="$(grep -oE 'line-rate="[0-9.]+"' "$ART" | head -1 | grep -oE '[0-9.]+' | awk '{printf "%.0f%%", $1 * 100}')"
      c1="$(grep -oE 'branch-rate="[0-9.]+"' "$ART" | head -1 | grep -oE '[0-9.]+' | awk '{printf "%.0f%%", $1 * 100}')"
    elif grep -q 'counter type="LINE"' "$ART"; then      # JaCoCo
      read -r lm lc <<< "$(grep -oE '<counter type="LINE" missed="[0-9]+" covered="[0-9]+"' "$ART" | tail -1 | grep -oE '[0-9]+' | tr '\n' ' ')"
      read -r bm bc <<< "$(grep -oE '<counter type="BRANCH" missed="[0-9]+" covered="[0-9]+"' "$ART" | tail -1 | grep -oE '[0-9]+' | tr '\n' ' ')"
      c0="$(pct "${lc:-0}" "$(( ${lm:-0} + ${lc:-0} ))" || true)"
      c1="$(pct "${bc:-0}" "$(( ${bm:-0} + ${bc:-0} ))" || true)"
    fi
    ;;
esac

REL="${ART#"$HC_ROOT"/}"
if [ -n "$c0" ]; then hc_emit "coverage.c0" "$c0"; else hc_skip "coverage.c0" "$REL から行網羅を読み取れない"; fi
if [ -n "$c1" ]; then hc_emit "coverage.c1" "$c1"; else hc_skip "coverage.c1" "$REL に分岐網羅が含まれていない"; fi

if [ -n "${HC_COVERAGE_C2:-}" ]; then
  hc_emit "coverage.c2" "$HC_COVERAGE_C2"
else
  hc_skip "coverage.c2" "条件網羅(c2)を出す計測が未検出（lcov / cobertura / jacoco は c2 を出力しない）"
fi
