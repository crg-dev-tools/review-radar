#!/usr/bin/env bash
# Tier B, script half of #2 — decides whether an extracted destination exists.
#
# The subagent reads free text and says *where* a claim points; this script says
# whether that place is real. Resolution is pure string matching (file exists,
# heading present, issue resolvable), so there is no room for an LLM to invent a
# verdict. See SKILL.md 原則: LLM に検証させない。
#
# Input (stdin or --in FILE), one TSV row per claim, as produced by the subagent:
#   <source_ref>\t<claim>\t<dest_kind>\t<dest_id>\t<verdict>
#     dest_kind : code | doc | spec | test | issue | symbol | url | -
#     dest_id   : path[:line] | path[:symbol] | path#heading | #123 | symbol | URL | -
#     verdict   : traceable | untraceable | notdebt
#
# `notdebt` exists because the marker grep also hits prose that merely mentions
# "TODO". Dropping those rows would leave the script's marker count and the
# breakdown silently disagreeing, so they are counted on their own line instead.
#
# Output: metric TSV on stdout; the missing rows to --detail-out.
#
# The two piles are kept apart by --prefix: #2 (offload claims: "already handled
# elsewhere") and #1 (TODOs whose destination is only readable from prose) are
# different things and must not be summed (brief §3 #2).
#
# Usage:
#   resolve-references.sh [--in FILE] [--detail-out FILE] [--prefix offload]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

IN="-"
DETAIL_OUT=""
PREFIX="offload"
DETAIL_TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --in) IN="$2"; shift 2 ;;
    --detail-out) DETAIL_OUT="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --detail-title) DETAIL_TITLE="$2"; shift 2 ;;
    *) printf 'resolve-references.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

INPUT="$(if [ "$IN" = "-" ]; then cat; else cat "$IN"; fi)"

REPO="$(hc_gh_repo)"

# Echoes "" when the destination resolves, otherwise the reason it does not.
resolve_reason() {
  local kind="$1" id="$2"

  case "$kind" in
    issue)
      local num="${id##*#}"
      num="${num//[!0-9]/}"
      [ -n "$num" ] || { printf '宛先の issue 番号を読み取れない'; return; }
      if ! hc_gh_ready || [ -z "$REPO" ]; then
        printf 'gh 未認証のため未解決'
        return
      fi
      # Ask for `state`, not `number`: gh echoes a requested `number` back
      # without querying, so `--json number` succeeds for issues that do not
      # exist. An issue number may also legitimately be a PR number.
      if gh issue view "$num" --repo "$REPO" --json state >/dev/null 2>&1; then return; fi
      if gh pr view "$num" --repo "$REPO" --json state >/dev/null 2>&1; then return; fi
      printf 'issue 不在'
      ;;
    code|doc|spec|test)
      local path anchor
      case "$id" in
        *"#"*) path="${id%%#*}"; anchor="${id#*#}" ;;
        *)     path="$id"; anchor="" ;;
      esac
      # A trailing :something is a line number or a symbol, not part of the path.
      local suffix=""
      case "$path" in
        *:*) suffix="${path##*:}"; path="${path%:*}" ;;
      esac
      if [ -d "$HC_ROOT/$path" ]; then return; fi
      [ -f "$HC_ROOT/$path" ] || { printf 'ファイル不在'; return; }
      if [ -n "$suffix" ]; then
        if printf '%s' "$suffix" | grep -qE '^[0-9]+$'; then
          local lines
          lines="$(wc -l < "$HC_ROOT/$path" | tr -d ' ')"
          [ "$suffix" -le "$((lines + 1))" ] || { printf '行番号が範囲外 (%s 行)' "$lines"; return; }
        else
          grep -qiF -- "$suffix" "$HC_ROOT/$path" || { printf 'ファイル内に %s が無い' "$suffix"; return; }
        fi
      fi
      if [ -n "$anchor" ]; then
        grep -qiF -- "$anchor" "$HC_ROOT/$path" || { printf '見出し「%s」が無い' "$anchor"; return; }
      fi
      ;;
    symbol)
      local hit
      hit="$(hc_git_grep "$(printf '%s' "$id" | sed 's/[][\.^$*+?(){}|]/\\&/g')" | head -1)"
      [ -n "$hit" ] || printf 'シンボルがリポジトリ内に無い'
      ;;
    *)
      printf '宛先種別が不明 (%s)' "$kind"
      ;;
  esac
}

verified=0
missing=0
untraceable=0
external=0
notdebt=0
detail=""

while IFS=$'\037' read -r src claim kind id verdict; do
  [ -n "${src:-}" ] || continue
  case "$src" in \#*) continue ;; esac  # allow comment rows in the input
  kind="$(printf '%s' "${kind:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  id="${id:-}"

  if [ "${verdict:-}" = "notdebt" ]; then
    notdebt=$(( notdebt + 1 ))
    continue
  fi

  if [ "${verdict:-}" = "untraceable" ] || [ -z "$id" ] || [ "$id" = "-" ] || [ "$id" = "null" ]; then
    untraceable=$(( untraceable + 1 ))
    continue
  fi

  # Destinations outside this repository cannot be settled by string matching.
  # They are reported on their own line instead of being forced into
  # verified / missing (原則: 測れない指標に値を代入しない).
  if [ "$kind" = "url" ] || case "$id" in http*://*) true ;; *) false ;; esac; then
    if [ -n "$REPO" ] && printf '%s' "$id" | grep -qF "$REPO/issues/"; then
      kind="issue"
      id="#$(printf '%s' "$id" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')"
    else
      external=$(( external + 1 ))
      continue
    fi
  fi

  reason="$(resolve_reason "$kind" "$id")"
  if [ -z "$reason" ]; then
    verified=$(( verified + 1 ))
  else
    missing=$(( missing + 1 ))
    detail="${detail}| \`${src}\` | ${claim} | \`${id}\` | ${reason} |"$'\n'
  fi
done <<< "$(printf '%s' "$INPUT" | hc_split 5)"

hc_emit "${PREFIX}.verified" "$verified"
hc_emit "${PREFIX}.missing" "$missing"
hc_emit "${PREFIX}.untraceable" "$untraceable"
[ "$external" -gt 0 ] && hc_emit "${PREFIX}.external" "$external"
[ "$notdebt" -gt 0 ] && hc_emit "${PREFIX}.notdebt" "$notdebt"

if [ -n "$DETAIL_OUT" ] && [ -n "$detail" ]; then
  {
    printf '### %s\n' "${DETAIL_TITLE:-詳細: traced-missing（要対応）}"
    printf '| 出所 | 主張 | 宛先 | 状態 |\n'
    printf '|---|---|---|---|\n'
    printf '%s' "$detail"
  } > "$DETAIL_OUT"
fi
exit 0
