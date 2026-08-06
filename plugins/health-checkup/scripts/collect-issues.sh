#!/usr/bin/env bash
# Tier A — stale open issues (#5) and open issues without a milestone (#6).
#
# Both are absolute counts over the current open-issue snapshot, so this script
# is stateless: no diff window, no backfill. `gh` is the only dependency; when it
# is missing or unauthenticated both metrics are skipped with a reason rather
# than defaulted to 0.
#
# Usage:
#   collect-issues.sh [--stale-days N] [--detail-out FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

DETAIL_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stale-days) HC_STALE_DAYS="$2"; shift 2 ;;
    --detail-out) DETAIL_OUT="$2"; shift 2 ;;
    *) printf 'collect-issues.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! hc_gh_ready; then
  reason="gh CLI が無い、または未認証（gh auth status で確認）"
  hc_skip "issues.stale" "$reason"
  hc_skip "issues.no_milestone" "$reason"
  exit 0
fi

REPO="$(hc_gh_repo)"
if [ -z "$REPO" ]; then
  reason="リポジトリを解決できない（gh repo view が失敗）"
  hc_skip "issues.stale" "$reason"
  hc_skip "issues.no_milestone" "$reason"
  exit 0
fi

# number, createdAt, updatedAt, milestone presence, title — one TSV row per open
# issue. --paginate is implied by gh issue list --limit.
RAW="$(gh issue list --repo "$REPO" --state open --limit 1000 \
  --json number,title,createdAt,updatedAt,milestone \
  --jq '.[] | [.number, .createdAt, .updatedAt, (if .milestone == null then "none" else "set" end), .title] | @tsv' \
  2>/dev/null || true)"

if [ -z "$RAW" ] && ! gh issue list --repo "$REPO" --state open --limit 1 >/dev/null 2>&1; then
  reason="issue の取得に失敗した（権限 / issues 無効の可能性）"
  hc_skip "issues.stale" "$reason"
  hc_skip "issues.no_milestone" "$reason"
  exit 0
fi

CUTOFF_EPOCH=$(( $(date +%s) - HC_STALE_DAYS * 86400 ))

stale=0
no_milestone=0
detail=""

while IFS=$'\t' read -r number created updated milestone title; do
  [ -n "${number:-}" ] || continue
  [ "$milestone" = "none" ] && no_milestone=$(( no_milestone + 1 ))
  # Stale = untouched (no update) for longer than the threshold.
  upd_epoch="$(date -d "$updated" +%s 2>/dev/null || echo 0)"
  if [ "$upd_epoch" -gt 0 ] && [ "$upd_epoch" -lt "$CUTOFF_EPOCH" ]; then
    stale=$(( stale + 1 ))
    days=$(( ( $(date +%s) - upd_epoch ) / 86400 ))
    detail="${detail}| #${number} | ${title} | ${days} 日 | ${created%T*} |"$'\n'
  fi
done <<< "$RAW"

hc_emit "issues.stale" "$stale"
hc_emit "issues.no_milestone" "$no_milestone"

if [ -n "$DETAIL_OUT" ] && [ -n "$detail" ]; then
  {
    printf '### 詳細: 長期滞留 issue (>%s日)\n' "$HC_STALE_DAYS"
    printf '| issue | タイトル | 最終更新からの日数 | 作成日 |\n'
    printf '|---|---|---|---|\n'
    printf '%s' "$detail"
  } > "$DETAIL_OUT"
fi
