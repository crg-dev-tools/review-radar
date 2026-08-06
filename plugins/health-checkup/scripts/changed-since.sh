#!/usr/bin/env bash
# Prints the tracked files touched since the previous checkup, one per line.
#
# The previous date comes from the last dated section of health.md (sections
# dated today are ignored, so a same-day re-run keeps the same window). Prints
# nothing when there is no previous checkup — that is the baseline run, which
# starts the stock at 0 instead of scanning the whole history.
#
# The skill uses this to decide whether to spawn the subagent at all: an empty
# list with a previous checkup present means nothing changed, so no LLM is spent.
#
# Usage:
#   changed-since.sh [--count] [--since YYYY-MM-DD]
# Exit status is always 0; `--count` prints the number of paths instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

COUNT=0
SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT=1; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    *) printf 'changed-since.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PATHS="$(printf '%s' "$(hc_changed_paths "$SINCE")" | hc_filter_paths)"

if [ "$COUNT" -eq 1 ]; then
  printf '%s\n' "$(printf '%s' "$PATHS" | grep -c . || true)"
else
  [ -n "$PATHS" ] && printf '%s\n' "$PATHS"
fi
exit 0
