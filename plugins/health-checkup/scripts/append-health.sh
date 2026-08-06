#!/usr/bin/env bash
# The vessel — writes one dated section to health.md and prints the short
# summary that the skill returns to its caller.
#
# Every section carries a machine-readable `<!-- hc-data: ... -->` line, which is
# how the next run reads the previous values. That keeps the trend inside the
# health file itself: no separate state file, and no LLM doing arithmetic.
#
# Re-running on the same date replaces that date's section (and still compares
# against the section before it), so the script is idempotent.
#
# With HC_OUTPUT_FORMAT=md+html (or --html) the HTML view is re-rendered from the
# freshly written Markdown, so an unattended run needs no second call.
#
# Usage:
#   append-health.sh [metrics.tsv ...] [--metrics -] [--detail FILE]... [--note TEXT] [--html]
# Metric rows are `<key>\t<value>\t<status>\t<reason>`; `--metrics -` reads stdin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

METRIC_INPUT=""
DETAILS=()
NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --metrics)
      if [ "$2" = "-" ]; then METRIC_INPUT="${METRIC_INPUT}$(cat)"$'\n'; else METRIC_INPUT="${METRIC_INPUT}$(cat "$2")"$'\n'; fi
      shift 2 ;;
    --detail) DETAILS+=("$2"); shift 2 ;;
    --note) NOTE="$2"; shift 2 ;;
    --html) HC_OUTPUT_FORMAT="md+html"; shift ;;
    -*) printf 'append-health.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    *) METRIC_INPUT="${METRIC_INPUT}$(cat "$1")"$'\n'; shift ;;
  esac
done

[ -n "$METRIC_INPUT" ] || { printf 'append-health.sh: no metrics given\n' >&2; exit 2; }

HEALTH="$(hc_health_path)"

# --- registry: display order, label, baseline (shared with render-html.sh) -----
REGISTRY_FILE="${HC_REGISTRY_FILE:-$SCRIPT_DIR/metrics-registry.tsv}"
[ -f "$REGISTRY_FILE" ] || { printf 'append-health.sh: registry not found: %s\n' "$REGISTRY_FILE" >&2; exit 2; }

declare -A VALUE=() STATUS=() REASON=() LABEL=() BASELINE=() SEEN=()
ORDER=()
REG_ORDER=()

while IFS=$'\037' read -r k l b _group _desc; do
  case "$k" in ''|'#'*) continue ;; esac
  REG_ORDER+=("$k")
  LABEL["$k"]="${l//\{HC_STALE_DAYS\}/$HC_STALE_DAYS}"
  BASELINE["$k"]="$b"
done <<< "$(hc_split 5 < "$REGISTRY_FILE")"

while IFS=$'\037' read -r key value status reason; do
  [ -n "${key:-}" ] || continue
  case "$key" in \#*) continue ;; esac
  if [ -z "${SEEN[$key]:-}" ]; then
    SEEN["$key"]=1
    ORDER+=("$key")
  fi
  VALUE["$key"]="${value:-}"
  STATUS["$key"]="${status:-ok}"
  REASON["$key"]="${reason:-}"
  [ -n "${LABEL[$key]:-}" ] || { LABEL["$key"]="$key"; BASELINE["$key"]="—"; }
done <<< "$(printf '%s' "$METRIC_INPUT" | hc_split 4)"

# --- previous values ----------------------------------------------------------
# Today's section, if any, is dropped first so a same-day re-run compares against
# the previous checkup rather than against itself.
BODY=""
if [ -f "$HEALTH" ]; then
  BODY="$(awk -v today="## $HC_DATE" '
    $0 == today { skip = 1; next }
    /^## / { skip = 0 }
    !skip { print }
  ' "$HEALTH")"
fi

declare -A PREV=()
if [ -n "$BODY" ]; then
  prev_line="$(printf '%s\n' "$BODY" | grep '^<!-- hc-data:' | tail -1 || true)"
  if [ -n "$prev_line" ]; then
    prev_line="${prev_line#<!-- hc-data:}"
    prev_line="${prev_line%-->}"
    IFS=';' read -r -a pairs <<< "$prev_line"
    for p in "${pairs[@]}"; do
      p="${p# }"; p="${p% }"
      [ -n "$p" ] || continue
      PREV["${p%%=*}"]="${p#*=}"
    done
  fi
fi

# --- section -----------------------------------------------------------------
emit_order() { # registry order first, then any unknown keys as given
  local k rk known
  for k in "${REG_ORDER[@]}"; do
    [ -n "${SEEN[$k]:-}" ] && printf '%s\n' "$k"
  done
  for k in "${ORDER[@]}"; do
    known=0
    for rk in "${REG_ORDER[@]}"; do [ "$rk" = "$k" ] && known=1; done
    [ "$known" -eq 0 ] && printf '%s\n' "$k"
  done
}

data_pairs=""
table=""
skipped=""
while IFS= read -r k; do
  [ -n "$k" ] || continue
  prev="${PREV[$k]:-—}"
  if [ "${STATUS[$k]}" = "skipped" ]; then
    table="${table}| ${LABEL[$k]} | skipped | ${prev} | ${BASELINE[$k]} |"$'\n'
    skipped="${skipped}| ${LABEL[$k]} | ${REASON[$k]} |"$'\n'
    data_pairs="${data_pairs}${k}=skipped;"
  else
    v="${VALUE[$k]}"
    table="${table}| ${LABEL[$k]} | ${v} | ${prev} | ${BASELINE[$k]} |"$'\n'
    data_pairs="${data_pairs}${k}=${v//;/,};"
  fi
done <<< "$(emit_order)"

{
  if [ ! -f "$HEALTH" ]; then
    printf '# Health Checkup\n\n'
    printf 'リポジトリの定期健診ログ。**数値と基準値を並置するだけで、診断は書かない**（診断は人間がやる）。\n'
    printf '各セクションは追記のみ。`<!-- hc-data: -->` 行は次回の「前回」列を読むための機械可読データ。\n\n'
  else
    # BODY loses its trailing newlines to command substitution; restore the
    # blank line that separates it from the section appended below.
    printf '%s\n\n' "$BODY"
  fi
  printf '## %s\n' "$HC_DATE"
  printf '<!-- hc-data: %s -->\n\n' "$data_pairs"
  [ -n "$NOTE" ] && printf '> %s\n\n' "$NOTE"
  printf '| 指標 | 値 | 前回 | 基準 |\n'
  printf '|---|---|---|---|\n'
  printf '%s\n' "$table"
  for d in "${DETAILS[@]:-}"; do
    [ -n "${d:-}" ] && [ -f "$d" ] && { cat "$d"; printf '\n'; }
  done
  if [ -n "$skipped" ]; then
    printf '### skipped\n'
    printf '| 指標 | reason |\n'
    printf '|---|---|\n'
    printf '%s\n' "$skipped"
  fi
} > "$HEALTH.tmp"

mv "$HEALTH.tmp" "$HEALTH"

# --- summary for the caller (§4.2: 全文は health.md、起動元には数行だけ) ------
summary=""
add() { # add <key> <label>
  local k="$1" l="$2"
  [ -n "${SEEN[$k]:-}" ] || return 0
  [ "${STATUS[$k]}" = "skipped" ] && return 0
  local prev="${PREV[$k]:-}"
  if [ -n "$prev" ] && [ "$prev" != "—" ] && [ "$prev" != "skipped" ]; then
    summary="${summary}${l}=${VALUE[$k]} (前回 ${prev}), "
  else
    summary="${summary}${l}=${VALUE[$k]}, "
  fi
}
add "offload.missing" "traced-missing"
add "offload.untraceable" "untraceable"
add "todo.unreferenced" "TODO(参照なし)"
add "todo.referenced_missing" "TODO(issue不在)"
add "issues.stale" "滞留 issue"
add "issues.no_milestone" "milestone なし"

printf 'Health Checkup %s: %s\n' "$HC_DATE" "${summary%, }"
if [ -n "$skipped" ]; then
  # Labels only, and at most five of them: the reasons stay in health.md so the
  # caller still gets a few lines (§4.2).
  n_skipped="$(printf '%s' "$skipped" | grep -c . || true)"
  labels="$(printf '%s' "$skipped" | sed -E 's/^\| ([^|]+) \| .*$/\1/' | head -5 | paste -sd',' - | sed 's/,/, /g')"
  if [ "$n_skipped" -gt 5 ]; then
    printf 'skipped: %s 件 — %s 他 %s 件（reason は health.md）\n' "$n_skipped" "$labels" "$(( n_skipped - 5 ))"
  else
    printf 'skipped: %s 件 — %s（reason は health.md）\n' "$n_skipped" "$labels"
  fi
fi
[ -n "$NOTE" ] && printf 'note: %s\n' "$NOTE"

if case "$HC_OUTPUT_FORMAT" in *html*) true ;; *) false ;; esac; then
  rendered="$(bash "$SCRIPT_DIR/render-html.sh" --in "$HEALTH" || true)"
  printf '詳細: %s / %s\n' "${HEALTH#"$HC_ROOT"/}" "${rendered:-html 生成に失敗}"
else
  printf '詳細: %s\n' "${HEALTH#"$HC_ROOT"/}"
fi
