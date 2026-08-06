#!/usr/bin/env bash
# Tier D — spec / implementation drift (#7), measured through its proxy.
#
# Drift itself needs an LLM to measure, so it is replaced by the proxy that comes
# closest to it and is mechanically countable: spec items derived from the code
# but never confirmed by a human (`provenance: observed`).
#
# The other two proxies from the brief (feature areas with no spec, shipped
# changes not reflected in the spec) have no mechanical definition, so they are
# recorded as skipped instead of being approximated.
#
# Usage:
#   collect-spec-drift.sh [--spec-dirs "a b"] [--detail-out FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

DETAIL_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec-dirs) HC_SPEC_DIRS="$2"; shift 2 ;;
    --detail-out) DETAIL_OUT="$2"; shift 2 ;;
    *) printf 'collect-spec-drift.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROVENANCE_RE="${HC_PROVENANCE_RE:-provenance:[[:space:]]*observed}"

SPECS=""
for d in $HC_SPEC_DIRS; do
  [ -d "$HC_ROOT/$d" ] && SPECS="$SPECS $d"
done
SPECS="${SPECS# }"

hc_skip "spec.missing_area" "spec 未整備の機能領域は機械的に定義できない（要 LLM。本プラグインでは測らない）"
hc_skip "spec.unreflected" "spec 未反映の実装変更は機械的に定義できない（要 LLM。本プラグインでは測らない）"

if [ -z "$SPECS" ]; then
  hc_skip "spec.unconfirmed" "spec 基盤なし（$HC_SPEC_DIRS が無い）"
  exit 0
fi

# shellcheck disable=SC2086
HITS="$(cd "$HC_ROOT" && grep -rnE "$PROVENANCE_RE" $SPECS 2>/dev/null || true)"
COUNT="$(printf '%s' "$HITS" | grep -c . || true)"

hc_emit "spec.unconfirmed" "${COUNT:-0}"

if [ -n "$DETAIL_OUT" ] && [ "${COUNT:-0}" -gt 0 ]; then
  {
    printf '### 詳細: 人間が意図確認していない spec 項目\n'
    printf '| 出所 |\n'
    printf '|---|\n'
    printf '%s' "$HITS" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '| `%s` |\n' "$(printf '%s' "$line" | cut -d: -f1,2)"
    done
  } > "$DETAIL_OUT"
fi
