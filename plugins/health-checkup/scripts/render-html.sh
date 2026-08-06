#!/usr/bin/env bash
# Renders health.md into a self-contained health.html.
#
# The Markdown file stays the source of truth (the `hc-data` lines are the state
# the next run reads); this is a read-only view of it. Deleting the HTML loses
# nothing, so it can be regenerated at any time from the Markdown alone.
#
# What the view adds over the raw Markdown:
#   * the newest section expanded, older ones collapsed into <details>
#   * numeric values compared against 前回 and marked ▲ / ▼ / →
#   * rows whose baseline is 0 but whose value is not are marked as 要対応
#   * skipped rows muted, so a skipped metric never reads as a zero
#
# No external renderer is used (no pandoc, no network): the input format is the
# one append-health.sh writes, so it is parsed directly. Style follows the
# viewer's light / dark preference.
#
# Usage:
#   render-html.sh [--in health.md] [--out health.html] [--title TEXT]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$SCRIPT_DIR/_common.sh"
hc_load_config

IN=""
OUT=""
TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --in) IN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) printf 'render-html.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$IN" ] || IN="$(hc_health_path)"
if [ ! -f "$IN" ]; then
  printf 'render-html.sh: %s が無い（先に append-health.sh を実行する）\n' "$IN" >&2
  exit 1
fi
if [ -z "$OUT" ]; then
  OUT="${HC_HTML_FILE:-${IN%.md}.html}"
  case "$OUT" in /*|?:*) ;; *) OUT="$HC_ROOT/$OUT" ;; esac
fi
[ -n "$TITLE" ] || TITLE="Health Checkup — $(basename "$HC_ROOT")"

REGISTRY_FILE="${HC_REGISTRY_FILE:-$SCRIPT_DIR/metrics-registry.tsv}"

awk -v title="$TITLE" -v src="${IN#"$HC_ROOT"/}" -v regfile="$REGISTRY_FILE" \
    -v stale_days="$HC_STALE_DAYS" '
function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  return s
}
function inline(s) {
  s = esc(s)
  while (match(s, /\*\*[^*]+\*\*/)) {
    t = substr(s, RSTART + 2, RLENGTH - 4)
    s = substr(s, 1, RSTART - 1) "<strong>" t "</strong>" substr(s, RSTART + RLENGTH)
  }
  while (match(s, /`[^`]+`/)) {
    t = substr(s, RSTART + 1, RLENGTH - 2)
    s = substr(s, 1, RSTART - 1) "<code>" t "</code>" substr(s, RSTART + RLENGTH)
  }
  return s
}
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
# Prints one buffered section, wrapping tables so wide ones scroll on their own.
function dump(s,   i, l) {
  for (i = 1; i <= nline[s]; i++) {
    l = buf[s, i]
    if (l ~ /^<table>/) print "<div class=\"tw\">"
    print l
    if (l == "</tbody></table>") print "</div>"
  }
}
function plain(s) { gsub(/[*`]/, "", s); return trim(s) }
# A value that can be compared: leading number, ignoring % and counts in ().
function numof(s, t) {
  t = plain(s)
  if (t ~ /^-?[0-9]+(\.[0-9]+)?%?/) { sub(/%.*$/, "", t); sub(/[^0-9.-].*$/, "", t); return t + 0 }
  return "NaN"
}
function close_table() {
  if (in_table) { emit("</tbody></table>"); in_table = 0 }
}
# Lines are buffered per section, because health.md is append-only (oldest
# first) while the view wants the newest section on top.
function emit(s) { if (section > 0) { nline[section]++; buf[section, nline[section]] = s } }

BEGIN {
  section = 0; in_table = 0; ncol = 0; ngrp = 0
  # The registry maps a label to its group and its tooltip. Read by label because
  # that is what the Markdown table carries; append-health.sh writes the labels
  # from this same file, so the two cannot drift apart.
  while ((getline line < regfile) > 0) {
    if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
    n = split(line, f, /\t/)
    if (n < 5) continue
    lab = f[2]; gsub(/\{HC_STALE_DAYS\}/, stale_days, lab)
    dsc = f[5]; gsub(/\{HC_STALE_DAYS\}/, stale_days, dsc)
    lab = plain(lab)
    grp_of[lab] = f[4]
    desc_of[lab] = dsc
    reg_label[++nreg] = lab          # file order, so the listing below is stable
    if (!(f[4] in grp_seen)) { grp_seen[f[4]] = ++ngrp }
  }
  close(regfile)
}

/^# / { doc_title = trim(substr($0, 3)); next }

/^<!-- hc-data:/ { next }

/^## / {
  close_table()
  section++
  date[section] = trim(substr($0, 4))
  nline[section] = 0
  alertn[section] = 0
  next
}

/^### / {
  close_table()
  emit("<h3>" inline(trim(substr($0, 5))) "</h3>")
  next
}

/^> / {
  close_table()
  emit("<p class=\"note\">" inline(trim(substr($0, 3))) "</p>")
  next
}

/^\|/ {
  line = $0
  sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
  n = split(line, cell, /\|/)
  # separator row
  if (cell[1] ~ /^[ \t]*:?-+:?[ \t]*$/) { next }
  if (!in_table) {
    in_table = 1; ncol = n; cur_group = ""
    # Only the 指標 / 値 / 前回 / 基準 table gets trends, grouping and tooltips —
    # the detail tables are four columns too, and must stay plain.
    is_metric = (n == 4 && trim(cell[1]) == "指標" && trim(cell[2]) == "値")
    emit("<table><thead><tr>")
    for (i = 1; i <= n; i++) emit("<th>" inline(trim(cell[i])) "</th>")
    emit("</tr></thead><tbody>")
    next
  }
  # 指標 | 値 | 前回 | 基準 rows get the comparison treatment
  cls = ""; trend = ""
  if (is_metric && n == 4) {
    v = plain(cell[2]); p = plain(cell[3]); b = plain(cell[4])
    if (v == "skipped") {
      cls = " class=\"muted\""
    } else {
      vn = numof(v); pn = numof(p)
      if (vn != "NaN" && pn != "NaN") {
        # Direction is read from the baseline column: 上昇 means higher is
        # better, 減少 / 0 means lower is better, anything else is neutral.
        # Colouring every rise red would call a coverage gain a regression.
        if (b ~ /上昇/) better = 1
        else if (b ~ /減少/ || b == "0") better = -1
        else better = 0
        if (vn == pn) trend = "<span class=\"flat\">→</span>"
        else {
          dirn = (vn > pn) ? 1 : -1
          k = (better == 0) ? "flat" : ((dirn == better) ? "good" : "bad")
          trend = "<span class=\"" k "\">" ((dirn == 1) ? "▲" : "▼") "</span>"
        }
      }
      if (b == "0" && vn != "NaN" && vn != 0) { cls = " class=\"alert\""; alertn[section]++ }
    }
  }
  # Group heading rows, so 20 metrics read as five short blocks rather than one
  # undifferentiated list. Rows arrive in registry order, so a change of group is
  # the boundary.
  if (is_metric && n == 4) {
    lab = plain(cell[1])
    g = (lab in grp_of) ? grp_of[lab] : "その他"
    if (g != cur_group) {
      emit("<tr class=\"grp\"><th colspan=\"4\">" esc(g) "</th></tr>")
      cur_group = g
    }
    # Recorded per section: the newest section is the last one parsed, not the
    # first, so which metrics to describe can only be decided in END.
    if (lab in desc_of) desc_in[section, lab] = 1
  }

  emit("<tr" cls ">")
  for (i = 1; i <= n; i++) {
    c = inline(trim(cell[i]))
    if (i == 2 && trend != "") c = c " " trend
    # The tooltip says what the number counts; the same text is listed in the
    # 指標の説明 block below, because hover is not available everywhere.
    if (i == 1 && is_metric && (lab in desc_of))
      emit("<td><span class=\"hint\" title=\"" esc(desc_of[lab]) "\">" c "</span></td>")
    else
      emit("<td>" c "</td>")
  }
  emit("</tr>")
  next
}

/^[ \t]*$/ { close_table(); next }

{
  close_table()
  emit("<p>" inline($0) "</p>")
}

END {
  close_table()
  latest = section

  print "<!DOCTYPE html>"
  print "<html lang=\"ja\"><head><meta charset=\"utf-8\">"
  print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  print "<title>" esc(title) "</title>"
  print "<style>"
  print ":root{--bg:#fff;--fg:#1a1a1a;--dim:#666;--line:#e3e3e3;--card:#fafafa;--alert:#b3261e;--alertbg:#fdecea;--bad:#b3261e;--good:#1b7f4b;--flat:#888;--tag:#3d5afe}"
  print "@media (prefers-color-scheme:dark){:root{--bg:#16181c;--fg:#e8e8e8;--dim:#9aa0a6;--line:#2c3038;--card:#1d2027;--alert:#ff6b6b;--alertbg:#3a1f1f;--bad:#ff8a80;--good:#69db7c;--flat:#777;--tag:#8c9eff}}"
  print "*{box-sizing:border-box}body{margin:0;padding:2rem 1.25rem 4rem;background:var(--bg);color:var(--fg);font:15px/1.7 -apple-system,\"Segoe UI\",\"Noto Sans JP\",sans-serif}"
  print "main{max-width:56rem;margin:0 auto}h1{font-size:1.45rem;margin:0 0 .25rem}h2{font-size:1.15rem;margin:2rem 0 .75rem}h3{font-size:.95rem;margin:1.5rem 0 .5rem;color:var(--dim)}"
  print ".sub{color:var(--dim);font-size:.85rem;margin:0 0 2rem}.tag{font-size:.7rem;color:var(--tag);border:1px solid var(--tag);border-radius:999px;padding:.1rem .5rem;vertical-align:middle}"
  print ".ok,.warn{border-radius:.5rem;padding:.75rem 1rem;margin:0 0 1rem;font-size:.9rem}.ok{background:var(--card);color:var(--dim)}.warn{background:var(--alertbg);color:var(--alert);font-weight:600}"
  print ".note{background:var(--card);border-left:3px solid var(--line);padding:.6rem .9rem;color:var(--dim);font-size:.88rem;margin:0 0 1rem}"
  print "div.tw{overflow-x:auto;margin:0 0 1rem}table{border-collapse:collapse;width:100%;font-size:.9rem}"
  print "th,td{text-align:left;padding:.45rem .6rem;border-bottom:1px solid var(--line);white-space:nowrap}"
  print "th{font-size:.78rem;text-transform:uppercase;letter-spacing:.04em;color:var(--dim);font-weight:600}"
  print "td:first-child,th:first-child{white-space:normal}tr.muted td{color:var(--dim)}tr.alert td{background:var(--alertbg)}tr.alert td:first-child{font-weight:600;color:var(--alert)}"
  print "tr.grp th{padding-top:1.1rem;font-size:.8rem;color:var(--fg);letter-spacing:.02em;border-bottom:1px solid var(--line);text-transform:none}"
  print "tr.grp:first-child th{padding-top:.2rem}.hint{border-bottom:1px dotted var(--dim);cursor:help}td.dsc{white-space:normal;color:var(--dim);font-size:.85rem}"
  print ".good{color:var(--good)}.bad{color:var(--bad)}.flat{color:var(--flat)}code{background:var(--card);padding:.1rem .3rem;border-radius:.25rem;font-size:.85em}"
  print "details{margin:.35rem 0}summary{cursor:pointer;color:var(--dim);padding:.3rem 0}h2.past{font-size:.95rem;color:var(--dim);border-top:1px solid var(--line);padding-top:1.25rem}"
  print "footer{margin-top:3rem;color:var(--dim);font-size:.8rem;border-top:1px solid var(--line);padding-top:1rem}"
  print "</style></head><body><main>"
  print "<h1>" esc(doc_title == "" ? title : doc_title) "</h1>"
  print "<p class=\"sub\">数値と基準値を並置するだけの計器です。診断は書きません（診断は人間がやる）。最新: " esc(date[latest]) "</p>"

  if (latest < 1) {
    print "<p class=\"ok\">健診セクションがまだありません。</p></main></body></html>"
    exit
  }

  if (alertn[latest] > 0)
    print "<p class=\"warn\">要対応 " alertn[latest] " 件 — 基準が 0 の指標に値が入っています（下表の赤い行）。</p>"
  else
    print "<p class=\"ok\">基準が 0 の指標はすべて 0 です。▲▼ は前回比。skipped は「測っていない」で、0 ではありません。</p>"

  print "<section class=\"latest\"><h2>" esc(date[latest]) " <span class=\"tag\">最新</span></h2>"
  dump(latest)
  print "</section>"

  if (latest > 1) {
    print "<h2 class=\"past\">過去の健診</h2>"
    for (s = latest - 1; s >= 1; s--) {
      print "<details><summary>" esc(date[s]) (alertn[s] > 0 ? " — 要対応 " alertn[s] " 件" : "") "</summary>"
      dump(s)
      print "</details>"
    }
  }

  # Same descriptions as the tooltips, in a readable list: hover does not exist
  # on touch devices, and this doubles as the definition of each metric.
  # Counted before printing: only the groups and metrics actually present in the
  # newest section are described.
  nshown = 0; gshown = 0
  for (gi = 1; gi <= ngrp; gi++) {
    present = 0
    for (ri = 1; ri <= nreg; ri++) {
      l = reg_label[ri]
      if (grp_seen[grp_of[l]] == gi && ((latest, l) in desc_in)) { present = 1; nshown++ }
    }
    gshown += present
  }
  print "<h2 class=\"past\">指標の説明</h2>"
  print "<details><summary>この健診が何を数えているか（" nshown " 指標 / " gshown " 分類）</summary>"
  for (gi = 1; gi <= ngrp; gi++) {
    for (ri = 1; ri <= nreg; ri++) {
      l = reg_label[ri]
      if (grp_seen[grp_of[l]] != gi || !((latest, l) in desc_in)) continue
      if (!(gi in grp_printed)) {
        grp_printed[gi] = 1
        print "<h3>" esc(grp_of[l]) "</h3><div class=\"tw\"><table><tbody>"
      }
      print "<tr><td>" esc(l) "</td><td class=\"dsc\">" esc(desc_of[l]) "</td></tr>"
    }
    if (gi in grp_printed) print "</tbody></table></div>"
  }
  print "</details>"

  print "<footer>generated by review-radar / health-checkup from <code>" esc(src) "</code>. 追記のみ・append-only。</footer>"
  print "</main></body></html>"
}
' "$IN" > "$OUT.tmp"

mv "$OUT.tmp" "$OUT"
printf '%s\n' "${OUT#"$HC_ROOT"/}"
