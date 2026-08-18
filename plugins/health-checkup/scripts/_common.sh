#!/usr/bin/env bash
# Shared helpers for the health-checkup collect/append scripts.
#
# Every collect script writes metrics to stdout as TSV so that append-health.sh
# can consume them without a JSON parser:
#
#   <key>\t<value>\t<status>\t<reason>
#
# status is `ok` or `skipped`. A skipped metric carries an empty value and a
# reason; no default value is ever substituted (see SKILL.md, 原則).
#
# Configuration comes from environment variables, optionally pre-seeded by a
# `.health-checkup.env` file (KEY=value, shell syntax) at the repository root.
# Nothing here is required: unset keys fall back to the defaults below.

hc_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$PWD"
}

hc_load_config() {
  HC_ROOT="${HC_ROOT:-$(hc_repo_root)}"
  local cfg="$HC_ROOT/.health-checkup.env"
  # shellcheck disable=SC1090
  [ -f "$cfg" ] && . "$cfg"

  HC_HEALTH_FILE="${HC_HEALTH_FILE:-health.md}"
  HC_STALE_DAYS="${HC_STALE_DAYS:-90}"
  HC_TODO_MARKERS="${HC_TODO_MARKERS:-TODO|FIXME|XXX|HACK}"
  # Pathspecs limiting the offload/TODO scan. Empty = the whole tracked tree.
  HC_SCAN_PATHS="${HC_SCAN_PATHS:-}"
  # Paths matching this ERE are dropped from every scan (the health file itself
  # is always dropped). Use it to keep the scanner out of its own documentation.
  HC_EXCLUDE_RE="${HC_EXCLUDE_RE:-}"
  HC_SPEC_DIRS="${HC_SPEC_DIRS:-openspec/specs specs docs/spec doc/spec}"
  HC_E2E_DIRS="${HC_E2E_DIRS:-e2e tests/e2e test/e2e cypress playwright}"
  HC_COVERAGE_FILE="${HC_COVERAGE_FILE:-}"
  HC_DATE="${HC_DATE:-$(date +%F)}"
  # `md` or `md+html`. The Markdown file is always written — it holds the state
  # the next run reads — so the HTML is an additional view, never a replacement.
  # Set this in .health-checkup.env for unattended runs; interactively the skill
  # asks instead.
  HC_OUTPUT_FORMAT="${HC_OUTPUT_FORMAT:-md}"
  HC_HTML_FILE="${HC_HTML_FILE:-}"
  export HC_ROOT HC_HEALTH_FILE HC_STALE_DAYS HC_TODO_MARKERS HC_SCAN_PATHS \
    HC_EXCLUDE_RE HC_SPEC_DIRS HC_E2E_DIRS HC_COVERAGE_FILE HC_DATE \
    HC_OUTPUT_FORMAT HC_HTML_FILE
}

# Drops excluded paths from `path:...` or bare-path lines on stdin.
hc_filter_paths() {
  local health_rel="${HC_HEALTH_FILE#"$HC_ROOT"/}"
  awk -v ex="$HC_EXCLUDE_RE" -v health="$health_rel" '
    { p = $0; sub(/:.*$/, "", p) }
    p == health { next }
    ex != "" && p ~ ex { next }
    { print }
  '
}

hc_health_path() {
  case "$HC_HEALTH_FILE" in
    /*) printf '%s\n' "$HC_HEALTH_FILE" ;;
    *) printf '%s\n' "$HC_ROOT/$HC_HEALTH_FILE" ;;
  esac
}

# Re-delimits TSV on stdin with US (0x1f), padding to <n> fields.
#
# `IFS=$'\t' read` cannot be used directly: tab is IFS whitespace, so a run of
# tabs collapses into one delimiter and every field after an empty one shifts
# left — exactly what a skipped metric (empty value) produces. awk -F'\t' keeps
# empty fields, and US is not IFS whitespace, so the shift cannot happen.
hc_split() {
  local n="${1:-4}"
  awk -F'\t' -v n="$n" '{ for (i = 1; i <= n; i++) printf "%s%s", $i, (i < n ? "\037" : "\n") }'
}

# hc_emit <key> <value> [status] [reason]
hc_emit() {
  local key="$1" value="${2:-}" status="${3:-ok}" reason="${4:-}"
  printf '%s\t%s\t%s\t%s\n' "$key" "$value" "$status" "$reason"
}

# hc_skip <key> <reason>
hc_skip() {
  hc_emit "$1" "" "skipped" "$2"
}

hc_have() {
  command -v "$1" >/dev/null 2>&1
}

# Date of the most recent checkup strictly before HC_DATE. Empty when the health
# file has no earlier section — re-running on the same day therefore reuses the
# same diff window instead of collapsing it to nothing.
hc_last_date() {
  local f
  f="$(hc_health_path)"
  [ -f "$f" ] || return 0
  sed -n 's/^## \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$f" \
    | sort \
    | awk -v today="$HC_DATE" '$1 < today' \
    | tail -1
}

# Existing tracked files touched since the last checkup (or since $1). Prints
# nothing when there is no previous checkup (baseline run: stock starts at 0, no
# backfill).
hc_changed_paths() {
  local since="${1:-}"
  [ -n "$since" ] || since="$(hc_last_date)"
  [ -n "$since" ] || return 0
  # A bare YYYY-MM-DD makes git's approxidate fill in the *current* time of day,
  # which silently drops commits made earlier on that date. Pin it to midnight;
  # re-reading the day of the last checkup is cheap, missing a change is not.
  case "$since" in *[:\ ]*) ;; *) since="$since 00:00:00" ;; esac
  # shellcheck disable=SC2086
  git -C "$HC_ROOT" log --since="$since" --name-only --pretty=format: -- $HC_SCAN_PATHS \
    | sed '/^$/d' \
    | sort -u \
    | while IFS= read -r p; do
        [ -f "$HC_ROOT/$p" ] && printf '%s\n' "$p"
      done
  return 0   # an empty result is a normal outcome under `set -e`
}

# git grep over the tracked tree, honouring HC_SCAN_PATHS.
hc_git_grep() {
  local pattern="$1"
  # shellcheck disable=SC2086
  git -C "$HC_ROOT" grep -nIE "$pattern" -- $HC_SCAN_PATHS 2>/dev/null || true
}

# Repository in owner/name form, for gh calls. Empty when it cannot be resolved.
#
# Resolved from HC_ROOT's own remote, never from the current directory: the
# checkup may be pointed at a repository other than the one the session was
# started in, and asking `gh` where it is would then answer for the wrong repo —
# silently reporting another project's issues.
hc_gh_repo() {
  [ -n "${HC_GH_REPO:-}" ] && { printf '%s\n' "$HC_GH_REPO"; return 0; }
  local url slug
  url="$(git -C "$HC_ROOT" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then
    slug="${url%.git}"
    slug="${slug#*github.com[:/]}"
    case "$slug" in
      */*) printf '%s\n' "${slug#*://}"; return 0 ;;
    esac
  fi
  hc_have gh || return 0
  (cd "$HC_ROOT" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || true
}

hc_gh_ready() {
  hc_have gh && gh auth status >/dev/null 2>&1
}
