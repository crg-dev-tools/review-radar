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

NOW_EPOCH="$(date -u +%s)"
CUTOFF_ISO="$(date -u -d "@$(( NOW_EPOCH - HC_STALE_DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"

# Counted in one awk pass. `date -d` per issue is a process per issue, which costs
# over a minute on a repository with a few hundred open issues.
# Stale = untouched (no update) for longer than the threshold. GitHub timestamps
# are ISO 8601 UTC, so a plain string comparison orders them correctly.
DETAIL_TMP="$(mktemp)"
trap 'rm -f "$DETAIL_TMP"' EXIT

read -r stale no_milestone <<< "$(printf '%s\n' "$RAW" | awk -F'\t' \
  -v cutoff="$CUTOFF_ISO" -v now="$NOW_EPOCH" -v out="$DETAIL_TMP" '
  function epoch_of(iso,   d, t, p) {
    gsub(/[TZ]/, " ", iso); split(iso, p, /[- :]/)
    return mktime(p[1] " " p[2] " " p[3] " " p[4] " " p[5] " " p[6] " UTC")
  }
  $1 == "" { next }
  {
    if ($4 == "none") nm++
    if ($3 < cutoff) {
      stale++
      days = int((now - epoch_of($3)) / 86400)
      created = $2; sub(/T.*$/, "", created)
      print "| #" $1 " | " $5 " | " days " 日 | " created " |" > out
    }
  }
  END { print stale + 0, nm + 0 }')"

hc_emit "issues.stale" "$stale"
hc_emit "issues.no_milestone" "$no_milestone"

if [ -n "$DETAIL_OUT" ] && [ -s "$DETAIL_TMP" ]; then
  {
    printf '### 詳細: 長期滞留 issue (>%s日)\n' "$HC_STALE_DAYS"
    printf '| issue | タイトル | 最終更新からの日数 | 作成日 |\n'
    printf '|---|---|---|---|\n'
    cat "$DETAIL_TMP"
  } > "$DETAIL_OUT"
fi
