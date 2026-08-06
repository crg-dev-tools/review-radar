#!/usr/bin/env bash
# Tier D — e2e coverage (#4).
#
# The denominator is taken from the spec side (scenarios declared in
# HC_SPEC_DIRS), never from the test side: a denominator made of test files moves
# whenever tests are added, which makes the ratio meaningless. When no declared
# scenario count can be read, the metric is skipped — there is no fallback
# denominator (brief §3 #4, §8 未決 1 の決定).
#
# A scenario counts as covered when its title, or the slug of its title, appears
# anywhere under HC_E2E_DIRS.
#
# Usage:
#   collect-e2e.sh [--spec-dirs "a b"] [--e2e-dirs "a b"] [--detail-out FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

DETAIL_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec-dirs) HC_SPEC_DIRS="$2"; shift 2 ;;
    --e2e-dirs) HC_E2E_DIRS="$2"; shift 2 ;;
    --detail-out) DETAIL_OUT="$2"; shift 2 ;;
    *) printf 'collect-e2e.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

SCENARIO_RE="${HC_SCENARIO_RE:-^#+[[:space:]]*Scenario:}"

present_dirs() { # present_dirs <dir list>
  local d out=""
  for d in $1; do
    [ -d "$HC_ROOT/$d" ] && out="$out $d"
  done
  printf '%s\n' "${out# }"
}

SPECS="$(present_dirs "$HC_SPEC_DIRS")"
E2ES="$(present_dirs "$HC_E2E_DIRS")"

if [ -z "$SPECS" ]; then
  hc_skip "e2e.coverage" "宣言済みシナリオの分母が取得できない（spec 基盤なし: $HC_SPEC_DIRS が無い）"
  exit 0
fi

# shellcheck disable=SC2086
TITLES="$(cd "$HC_ROOT" && grep -rhE "$SCENARIO_RE" $SPECS 2>/dev/null \
  | sed -E 's/^#+[[:space:]]*Scenario:[[:space:]]*//' \
  | sed -E 's/[[:space:]]+$//' \
  | grep -v '^$' \
  | sort -u || true)"

TOTAL="$(printf '%s' "$TITLES" | grep -c . || true)"
if [ "${TOTAL:-0}" -eq 0 ]; then
  hc_skip "e2e.coverage" "spec に宣言済みシナリオ（${SCENARIO_RE}）が無く分母を取得できない"
  exit 0
fi

if [ -z "$E2ES" ]; then
  hc_skip "e2e.coverage" "e2e テストディレクトリが見つからない（HC_E2E_DIRS で指定）。分子が不定のため率を出さない"
  exit 0
fi

covered=0
uncovered=""
while IFS= read -r title; do
  [ -n "$title" ] || continue
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
  # shellcheck disable=SC2086
  if (cd "$HC_ROOT" && grep -rqiF -- "$title" $E2ES 2>/dev/null) \
    || { [ -n "$slug" ] && (cd "$HC_ROOT" && grep -rqiF -- "$slug" $E2ES 2>/dev/null); }; then
    covered=$(( covered + 1 ))
  else
    uncovered="${uncovered}| ${title} |"$'\n'
  fi
done <<< "$TITLES"

RATE="$(awk -v c="$covered" -v t="$TOTAL" 'BEGIN { printf "%.0f%%", (c * 100) / t }')"
hc_emit "e2e.coverage" "$RATE ($covered/$TOTAL)"

if [ -n "$DETAIL_OUT" ] && [ -n "$uncovered" ]; then
  {
    printf '### 詳細: e2e 未実装の宣言済みシナリオ\n'
    printf '| シナリオ |\n'
    printf '|---|\n'
    printf '%s' "$uncovered"
  } > "$DETAIL_OUT"
fi
