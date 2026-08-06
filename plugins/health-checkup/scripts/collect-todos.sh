#!/usr/bin/env bash
# Tier B, script half of #1 — the TODO / FIXME stock.
#
# Splits the markers found in the tracked tree into two piles:
#
#   * carrying a resolvable reference (`TODO(#128)`, `FIXME: see #42`, an issue
#     URL) — the reference is resolved with `gh`, so open / closed / missing is
#     decided by string matching, never by an LLM
#   * carrying none — written to --unreferenced-out for the subagent to read,
#     which is the only part of #1 that needs an LLM
#
# Absolute counts only. A residual *rate* would move with the habit of writing
# TODOs rather than with the health of the repository (see brief §3 #1).
#
# Usage:
#   collect-todos.sh [--unreferenced-out FILE] [--detail-out FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

UNREF_OUT=""
DETAIL_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unreferenced-out) UNREF_OUT="$2"; shift 2 ;;
    --detail-out) DETAIL_OUT="$2"; shift 2 ;;
    *) printf 'collect-todos.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

HITS="$(hc_git_grep "\\b(${HC_TODO_MARKERS})\\b" | hc_filter_paths)"

total=0
unreferenced=0
ref_lines=""
unref_lines=""

while IFS= read -r line; do
  [ -n "$line" ] || continue
  total=$(( total + 1 ))
  # A reference is an issue number on the same line, in any of the shapes that
  # actually occur: TODO(#128) / TODO: #128 / GH-128 / .../issues/128
  nums="$(printf '%s\n' "$line" \
    | grep -oE '(#[0-9]+|GH-[0-9]+|/issues/[0-9]+)' \
    | grep -oE '[0-9]+' \
    | sort -u \
    | tr '\n' ' ' || true)"
  if [ -n "${nums// /}" ]; then
    ref_lines="${ref_lines}${nums%% }|${line}"$'\n'
  else
    unreferenced=$(( unreferenced + 1 ))
    unref_lines="${unref_lines}${line}"$'\n'
  fi
done <<< "$HITS"

hc_emit "todo.total" "$total"
hc_emit "todo.unreferenced" "$unreferenced"

if [ -n "$UNREF_OUT" ]; then
  printf '%s' "$unref_lines" > "$UNREF_OUT"
fi

# --- referenced TODOs: resolve every number against the issue tracker ---------
if [ -z "$ref_lines" ]; then
  hc_emit "todo.referenced_open" "0"
  hc_emit "todo.referenced_missing" "0"
  exit 0
fi

REPO="$(hc_gh_repo)"
if ! hc_gh_ready || [ -z "$REPO" ]; then
  reason="gh CLI が無い / 未認証のため参照付き TODO の解決可否を判定できない"
  hc_skip "todo.referenced_open" "$reason"
  hc_skip "todo.referenced_missing" "$reason"
  exit 0
fi

ref_open=0
ref_closed=0
ref_missing=0
detail=""

# Resolve each distinct number once, then attribute the state to its lines.
declare -A STATE=()
while IFS= read -r row; do
  [ -n "$row" ] || continue
  nums="${row%%|*}"
  for n in $nums; do
    if [ -z "${STATE[$n]:-}" ]; then
      STATE[$n]="$(gh issue view "$n" --repo "$REPO" --json state --jq .state 2>/dev/null || true)"
      # An issue number may legitimately be a PR number.
      if [ -z "${STATE[$n]}" ]; then
        STATE[$n]="$(gh pr view "$n" --repo "$REPO" --json state --jq .state 2>/dev/null || true)"
      fi
      [ -n "${STATE[$n]}" ] || STATE[$n]="MISSING"
    fi
  done
done <<< "$ref_lines"

while IFS= read -r row; do
  [ -n "$row" ] || continue
  nums="${row%%|*}"
  loc="${row#*|}"
  worst=""
  for n in $nums; do
    case "${STATE[$n]}" in
      MISSING) worst="MISSING"; miss_n="$n"; break ;;
      OPEN) [ "$worst" = "" ] && { worst="OPEN"; } ;;
      *) [ "$worst" = "" ] && worst="CLOSED" ;;
    esac
  done
  case "$worst" in
    MISSING)
      ref_missing=$(( ref_missing + 1 ))
      detail="${detail}| \`${loc%%:*}:$(printf '%s' "$loc" | cut -d: -f2)\` | #${miss_n} | issue 不在 |"$'\n'
      ;;
    OPEN) ref_open=$(( ref_open + 1 )) ;;
    *) ref_closed=$(( ref_closed + 1 )) ;;
  esac
done <<< "$ref_lines"

hc_emit "todo.referenced_open" "$ref_open"
hc_emit "todo.referenced_missing" "$ref_missing"
# Closed-reference TODOs are dead code comments rather than debt: reported for
# context, with no baseline attached.
hc_emit "todo.referenced_closed" "$ref_closed"

if [ -n "$DETAIL_OUT" ] && [ -n "$detail" ]; then
  {
    printf '### 詳細: 参照付き TODO の宛先不在（要対応）\n'
    printf '| 出所 | 宛先 | 状態 |\n'
    printf '|---|---|---|\n'
    printf '%s' "$detail"
  } > "$DETAIL_OUT"
fi
