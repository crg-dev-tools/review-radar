#!/usr/bin/env bash
# Install the isolated-review TAKT assets (custom facets, workflow, perspective
# catalog) into the current project's ./.takt/ so `takt` can resolve them.
#
# Idempotent: existing files are left untouched unless --force is given, so
# per-project customizations (e.g. an edited catalog) are never clobbered.
#
# Usage:
#   setup-takt.sh [target-project-root] [--force]
# Defaults: target-project-root = current working directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/../takt"

TARGET_ROOT="$PWD"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) TARGET_ROOT="$arg" ;;
  esac
done

DEST="$TARGET_ROOT/.takt"

copy_one() {
  local rel="$1"
  local src="$SRC/$rel"
  local dst="$DEST/$rel"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" && "$FORCE" -ne 1 ]]; then
    echo "  skip (exists): $rel"
    return
  fi
  cp "$src" "$dst"
  echo "  installed: $rel"
}

echo "Installing isolated-review TAKT assets into $DEST"
# Walk every regular file under the plugin's takt/ tree and mirror it.
while IFS= read -r -d '' f; do
  rel="${f#"$SRC/"}"
  copy_one "$rel"
done < <(find "$SRC" -type f -print0)

echo "Done. Custom facets, workflow, and perspective catalog are available to takt."
echo "Builtin facets (coding-reviewer, security-reviewer, findings-manager, ...) resolve automatically."
