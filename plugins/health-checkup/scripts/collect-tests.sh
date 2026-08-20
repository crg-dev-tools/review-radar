#!/usr/bin/env bash
# Tier B, script half of #8 — tests that do not test.
#
# Coverage answers "was this line executed", which is the wrong question for two
# very common failures:
#
#   * a test that was switched off (`it.skip`, `@pytest.mark.skip`, `t.Skip`).
#     Coverage barely moves — other tests usually cover the same lines — so the
#     number never tells you the case stopped being checked.
#   * a test that runs but cannot fail (no assertion at all, an assertion that is
#     true by construction, or the subject itself mocked away). Coverage counts
#     it as *more* covered, so this failure makes the metric look better.
#
# Absolute counts only, never a rate: a residual rate would move with how many
# tests happen to be written rather than with the health of the suite.
#
# Skips are split the way TODOs are — carrying a resolvable issue reference or
# not — because "switched off and tracked" and "switched off and forgotten" are
# different things. The unreferenced ones go to --unreferenced-out for the
# subagent, which extracts *where the reason points*; whether that place exists
# is decided later by resolve-references.sh, never by an LLM.
#
# Every pattern here is deliberately narrow. A miss leaves a number one too low;
# a false positive makes people stop reading the whole report.
#
# Usage:
#   collect-tests.sh [--unreferenced-out FILE] [--detail-out FILE]
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
    *) printf 'collect-tests.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- which files are tests ----------------------------------------------------
# Name-based, because that is what the runners themselves match on. A test file
# the runner would not collect is *not* detected here — that needs the runner's
# config, and guessing it would produce a number nobody can act on.
# shellcheck disable=SC2086
TEST_FILES="$(git -C "$HC_ROOT" ls-files -- $HC_SCAN_PATHS 2>/dev/null \
  | grep -E '(\.(test|spec)\.[cm]?[jt]sx?$|_test\.go$|(^|/)test_[^/]+\.py$|_test\.py$|(Test|Tests)\.(java|kt|cs)$|_spec\.rb$|_test\.rb$|(^|/)__tests__/)' \
  | hc_filter_paths || true)"

if [ -z "$TEST_FILES" ]; then
  reason="テストファイルが見つからない（命名規約が既定と違う可能性）。分母が無いため数えない"
  for k in test.skip.total test.skip.unreferenced test.skip.referenced_open \
           test.skip.referenced_missing test.skip.referenced_closed \
           test.no_assertion test.always_true test.self_mocked; do
    hc_skip "$k" "$reason"
  done
  exit 0
fi
printf '%s\n' "$TEST_FILES" > "$TMP_DIR/files.txt"

# --- switched-off tests -------------------------------------------------------
SKIP_RE='(\b(it|test|describe|context|suite)\.(skip|todo)\b|\bx(it|describe|test|context)\(|@pytest\.mark\.(skip|skipif|xfail)|\bt\.Skip(Now)?\(|@(Ignore|Disabled)\b|\bpending\()'
SKIP_HITS="$(hc_git_grep "$SKIP_RE" | hc_filter_paths \
  | awk -v listfile="$TMP_DIR/files.txt" '
      BEGIN { while ((getline l < listfile) > 0) if (l != "") is[l] = 1 }
      { p = $0; sub(/:.*$/, "", p); if (p in is) print }
    ' || true)"

# Same single-pass split as collect-todos.sh: a pipeline per hit costs five
# processes per hit, which on Windows is the whole runtime.
# The reference must sit on the marker line itself. A reason written on the line
# above is invisible here on purpose — the subagent reads those instead.
SPLIT="$(printf '%s\n' "$SKIP_HITS" | awk '
  {
    if ($0 == "") next
    total++
    nums = ""; s = $0
    while (match(s, /(#|GH-|\/issues\/)[0-9]+/)) {
      m = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", m)
      if (index(" " nums " ", " " m " ") == 0) nums = nums (nums == "" ? "" : " ") m
      s = substr(s, RSTART + RLENGTH)
    }
    if (nums == "") { unref++; print "U\t" $0 }
    else { print "R\t" nums "|" $0 }
  }
  END { print "C\t" total + 0 "\t" unref + 0 }
')"

skip_total="$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1 == "C" { print $2 }')"
skip_unref="$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1 == "C" { print $3 }')"
unref_lines="$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1 == "U" { sub(/^U\t/, ""); print }')"
ref_lines="$(printf '%s\n' "$SPLIT" | awk -F'\t' '$1 == "R" { sub(/^R\t/, ""); print }')"

hc_emit "test.skip.total" "${skip_total:-0}"
hc_emit "test.skip.unreferenced" "${skip_unref:-0}"

[ -n "$UNREF_OUT" ] && printf '%s' "$unref_lines" > "$UNREF_OUT"

# --- tests that cannot fail ---------------------------------------------------
# One awk pass over the whole test tree — reading the files inside awk, not a
# grep per file.
#
#   no_assertion : not one assertion token in the file. Judged per file rather
#                  than per case, because case boundaries need a parser per
#                  language; a file with zero assertions is already unambiguous.
#   always_true  : an assertion that holds by construction. Only literal forms
#                  are matched (`expect(true).toBe(true)`, `assertTrue(true)`,
#                  `assert 1 == 1`). Anything cleverer would flag legitimate
#                  boundary assertions, so under-counting is chosen on purpose.
#   self_mocked  : the file mocks the module it is named after (foo.test.ts
#                  mocking './foo'). Mocking a *dependency* is normal and is not
#                  counted; mocking the subject means the test asserts against
#                  its own stub.
COUNTS="$(cd "$HC_ROOT" && awk -v out="$TMP_DIR/cannot-fail.tsv" '
  function subject(p,   b) {
    b = p; sub(/^.*\//, "", b)
    sub(/\.(test|spec)\.[cm]?[jt]sx?$/, "", b)
    sub(/_test\.(go|py|rb)$/, "", b); sub(/_spec\.rb$/, "", b)
    sub(/^test_/, "", b); sub(/\.(py|rb)$/, "", b)
    sub(/(Test|Tests)\.(java|kt|cs)$/, "", b)
    return b
  }
  $0 != "" {
    path = $0; subj = subject(path)
    has_assert = 0; at = 0; sm = 0
    while ((getline line < path) > 0) {
      if (line ~ /(expect\(|assert|\.should|should\.|\.to\.|t\.Error|t\.Fatal|require\.|assertThat|XCTAssert)/) has_assert = 1
      if (line ~ /expect\(true\)\.(toBe\(true\)|toBeTruthy\(\))/) at++
      else if (line ~ /expect\(false\)\.(toBe\(false\)|toBeFalsy\(\))/) at++
      else if (line ~ /expect\(1\)\.toBe\(1\)|expect\(0\)\.toBe\(0\)/) at++
      else if (line ~ /assertTrue\(true\)|XCTAssertTrue\(true\)|assert\.ok\(true\)/) at++
      else if (line ~ /assert +True *(,|$)|assert +1 *== *1|assert +True *\)/) at++
      if (subj != "" && line ~ /(vi|jest)\.mock\(/ && index(line, subj) > 0) sm = 1
      if (subj != "" && path ~ /\.py$/ && line ~ /(mock\.patch|@patch)\(/ && index(line, subj) > 0) sm = 1
    }
    close(path)
    if (!has_assert) { na++; print "N\t" path > out }
    if (sm) { selfmock++; print "S\t" path > out }
    alwaystrue += at
  }
  END { print (na + 0) "\t" (alwaystrue + 0) "\t" (selfmock + 0) }
' "$TMP_DIR/files.txt")"

hc_emit "test.no_assertion" "$(printf '%s' "$COUNTS" | awk -F'\t' '{ print $1 + 0 }')"
hc_emit "test.always_true" "$(printf '%s' "$COUNTS" | awk -F'\t' '{ print $2 + 0 }')"
hc_emit "test.self_mocked" "$(printf '%s' "$COUNTS" | awk -F'\t' '{ print $3 + 0 }')"

# --- green made in configuration ---------------------------------------------
# Not a property of any test: the suite is kept green by the runner or the CI
# definition. Counted apart because the fix lives in a different file from the
# tests, and because one line here can hide an entire suite.
CONFIG_RE='(--passWithNoTests|continue-on-error: *true|\|\| *true|\|\| *exit 0|retries? *[:=] *[1-9]|--retries?[ =][1-9]|flakyTestRetries|xfail_strict *= *false)'
CONFIG_HITS="$(hc_git_grep "$CONFIG_RE" | hc_filter_paths \
  | awk -F: '
      { p = $1 }
      p ~ /(^|\/)(package\.json|Makefile|pytest\.ini|setup\.cfg|pyproject\.toml|tox\.ini)$/ ||
      p ~ /(^|\/)\.github\/workflows\/[^\/]+\.ya?ml$/ ||
      p ~ /(jest|vitest|playwright|cypress|karma)\.config/ { print }
    ' || true)"
hc_emit "test.green_by_config" "$(printf '%s\n' "$CONFIG_HITS" | grep -c . || true)"

# --- referenced skips: resolve every number against the issue tracker ---------
miss_detail=""
if [ -z "$ref_lines" ]; then
  hc_emit "test.skip.referenced_open" "0"
  hc_emit "test.skip.referenced_missing" "0"
  hc_emit "test.skip.referenced_closed" "0"
else
  REPO="$(hc_gh_repo)"
  if ! hc_gh_ready || [ -z "$REPO" ]; then
    reason="gh CLI が無い / 未認証 / origin から owner・repo を解決できないため、参照付き skip の解決可否を判定できない"
    hc_skip "test.skip.referenced_open" "$reason"
    hc_skip "test.skip.referenced_missing" "$reason"
    hc_skip "test.skip.referenced_closed" "$reason"
  else
    ref_open=0; ref_closed=0; ref_missing=0
    declare -A STATE=()
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      for n in ${row%%|*}; do
        if [ -z "${STATE[$n]:-}" ]; then
          STATE[$n]="$(gh issue view "$n" --repo "$REPO" --json state --jq .state 2>/dev/null || true)"
          # An issue number may legitimately be a PR number.
          [ -n "${STATE[$n]}" ] || STATE[$n]="$(gh pr view "$n" --repo "$REPO" --json state --jq .state 2>/dev/null || true)"
          [ -n "${STATE[$n]}" ] || STATE[$n]="MISSING"
        fi
      done
    done <<< "$ref_lines"

    while IFS= read -r row; do
      [ -n "$row" ] || continue
      loc="${row#*|}"; worst=""; miss_n=""
      for n in ${row%%|*}; do
        case "${STATE[$n]}" in
          MISSING) worst="MISSING"; miss_n="$n"; break ;;
          OPEN) [ "$worst" = "" ] && worst="OPEN" ;;
          *) [ "$worst" = "" ] && worst="CLOSED" ;;
        esac
      done
      case "$worst" in
        MISSING)
          ref_missing=$(( ref_missing + 1 ))
          rest="${loc#*:}"
          miss_detail="${miss_detail}| \`${loc%%:*}:${rest%%:*}\` | #${miss_n} | issue 不在 |"$'\n'
          ;;
        OPEN) ref_open=$(( ref_open + 1 )) ;;
        *) ref_closed=$(( ref_closed + 1 )) ;;
      esac
    done <<< "$ref_lines"

    hc_emit "test.skip.referenced_open" "$ref_open"
    hc_emit "test.skip.referenced_missing" "$ref_missing"
    # Closed-reference skips are leftovers rather than debt: reported for
    # context, with no baseline attached.
    hc_emit "test.skip.referenced_closed" "$ref_closed"
  fi
fi

# --- detail -------------------------------------------------------------------
if [ -n "$DETAIL_OUT" ]; then
  {
    if [ -n "$miss_detail" ]; then
      printf '### 詳細: 参照付き skip の宛先不在（要対応）\n'
      printf '| 出所 | 宛先 | 状態 |\n|---|---|---|\n'
      printf '%s\n' "$miss_detail"
    fi
    if [ -s "$TMP_DIR/cannot-fail.tsv" ]; then
      printf '### 詳細: 落ちる条件が無いテスト\n'
      printf '| テストファイル | 種別 |\n|---|---|\n'
      awk -F'\t' '{ print "| `" $2 "` | " ($1 == "S" ? "対象自身を mock している" : "アサーションが 1 つも無い") " |" }' \
        "$TMP_DIR/cannot-fail.tsv"
      printf '\n'
    fi
    if [ -n "$CONFIG_HITS" ]; then
      printf '### 詳細: 設定で緑にしている箇所\n'
      printf '| 出所 | 記述 |\n|---|---|\n'
      printf '%s\n' "$CONFIG_HITS" | awk '
        { line = $0
          split(line, f, ":"); p = f[1]; ln = f[2]
          sub(/^[^:]*:[^:]*:/, "", line)
          gsub(/^[ \t]+|[ \t]+$/, "", line); gsub(/\|/, "\\|", line)
          print "| `" p ":" ln "` | `" substr(line, 1, 120) "` |" }'
    fi
  } > "$DETAIL_OUT"
fi
