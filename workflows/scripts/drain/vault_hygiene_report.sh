#!/usr/bin/env bash
#
# vault_hygiene_report.sh — detect-and-propose vault-maintenance probe.
#
# A periodic hygiene DETECTOR for the knowledge-store vault: nothing else
# alarms on drift, so silent pile-ups (162 _inbox stubs / 18 MB before anyone
# noticed — foundation #958) go unseen. This script only REPORTS; it never
# deletes or mutates vault content. /tidy runs it and appends alarms to
# a review surface; check-in disposes. Drain proposes, check-in
# disposes (foundation #959).
#
# Checks (over the vault root):
#   1. _inbox stubs      — count + oldest age; ALARM if >20 stubs or >48h.
#   2. closed plans       — Plans/*.md with status done|complete|abandoned still
#                           resident (should be archived+removed); ALARM if >0.
#   3. ledgers over cap   — named ledgers over a size/line cap (constants below).
#   4. garbage files      — zero-byte *.md, `..md` double-dot typos, stray
#                           `Users/`-tree paths; ALARM if any.
#   5. stale last_verified — count of provenance notes older than the staleness
#                            horizon (informational tally, not an alarm).
#
# Usage:
#   vault_hygiene_report.sh [--root DIR] [--format entry]
#     --root DIR       vault root (default: the knowledge_store seam's ks_root
#                      — KNOWLEDGE_STORE_ROOT if set, else its generic
#                      per-user default; see knowledge_store.sh)
#     --format entry   print a ready-to-append `### … Status: open` block IFF
#                      any alarm fires (nothing when clean); default prints a
#                      human-readable report + trailing `ALARM: <n>` / `OK`.
#
# Exit 0 always when the vault is reachable (a report is not a failure); exit 0
# with a one-line notice when the root is absent (a stranger's checkout has no
# vault — never fail the drain/CI). Exit 2 only on a usage error.
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) with BSD-vs-GNU
# stat/date fallbacks, so it runs on the macOS dev shell as well as Linux CI.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/lib/knowledge_store.sh
. "$HERE/../lib/knowledge_store.sh"

# ── Tunable caps (no machine cap existed before this script — foundation #959) ──
# INBOX_MAX_STUBS / INBOX_MAX_AGE_H are registered knobs (knob-registry.tsv) —
# tidy.md's own prose names them symbolically rather than restating the
# values (prose-tunables-migration, temperloop#164/#169 D3 follow-up).
: "${INBOX_MAX_STUBS:=20}"    # alarm above this many Sessions/_inbox stubs
: "${INBOX_MAX_AGE_H:=48}"    # alarm if the oldest stub is older than this (hours)
STALE_VERIFIED_DAYS=90      # last_verified older than this counts as stale
# Per-ledger line caps (entries ~ non-blank lines): a ledger over its cap is an
# alarm to prune at check-in. Indexed arrays (bash-3.2 safe) — LEDGER_PATHS[i]
# pairs with LEDGER_CAPS[i]. Paths may contain spaces, so an array (not a
# word-split string) is required.
LEDGER_PATHS=(
  "Context/Session friction ledger.md"
  "Context/pipeline - pending decisions.md"
  "Context/foundation - knowledge-search parity ledger.md"
)
LEDGER_CAPS=(250 120 400)

# ── Arg parse ─────────────────────────────────────────────────────────────────
ROOT="$(ks_root)"
FORMAT="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --root)   ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in report|entry) ;; *) echo "unknown --format: $FORMAT (report|entry)" >&2; exit 2 ;; esac

# ── Root-absent no-op (a stranger's checkout, or a mis-set root) ───────────────
if [ ! -d "$ROOT" ]; then
  [ "$FORMAT" = "entry" ] && exit 0   # nothing to append
  echo "vault hygiene: root not found ($ROOT) — skipping (no vault in this checkout)"
  exit 0
fi

# ── Portable stat/date helpers ────────────────────────────────────────────────
# Epoch mtime of a file (BSD `stat -f %m` vs GNU `stat -c %Y`).
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
# Current epoch without Date.now()-style pitfalls — plain `date` is fine here.
now_epoch() { date +%s; }

# Excludes for whole-vault walks: never descend Obsidian internals or the
# embedding store (thousands of files — CLAUDE.md forbids bulk-grepping it). The
# prune expression is inlined at each `find` (see below) rather than held in a
# word-split variable, so no unquoted expansion is needed.

alarms=0
inc() { alarms=$((alarms + 1)); }

# Findings accumulate as lines; entry-format wraps them, report-format lists them.
FINDINGS=""
add()  { FINDINGS="${FINDINGS}$1"$'\n'; }

# ── Check 1: _inbox stubs ─────────────────────────────────────────────────────
INBOX="$ROOT/Sessions/_inbox"
stub_count=0
oldest_age_h=0
if [ -d "$INBOX" ]; then
  now="$(now_epoch)"
  oldest_epoch="$now"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    stub_count=$((stub_count + 1))
    m="$(file_mtime "$f")"
    [ "$m" -lt "$oldest_epoch" ] && oldest_epoch="$m"
  done <<EOF
$(find "$INBOX" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
EOF
  if [ "$stub_count" -gt 0 ]; then
    oldest_age_h=$(( (now - oldest_epoch) / 3600 ))
  fi
fi
if [ "$stub_count" -gt "$INBOX_MAX_STUBS" ] || [ "$oldest_age_h" -gt "$INBOX_MAX_AGE_H" ]; then
  add "- ⚠️ _inbox: ${stub_count} stubs, oldest ${oldest_age_h}h (caps: >${INBOX_MAX_STUBS} stubs / >${INBOX_MAX_AGE_H}h) — run /tidy"
  inc
else
  add "- ok _inbox: ${stub_count} stubs, oldest ${oldest_age_h}h"
fi

# ── Check 2: closed plans still resident in Plans/ ────────────────────────────
PLANS="$ROOT/Plans"
closed_plans=0
closed_list=""
if [ -d "$PLANS" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Frontmatter status: read the first `status:` line in the file's head.
    # `|| true`: a plan legitimately lacking a status: line makes grep exit 1,
    # which pipefail+set -e would otherwise treat as fatal. The sed strips
    # surrounding quotes so `status: "done"` matches like bare `status: done`.
    st="$(grep -m1 -iE '^status:[[:space:]]*' "$f" 2>/dev/null | sed -e 's/^[Ss]tatus:[[:space:]]*//' -e 's/["'\'']//g' | tr -d '\r' | tr '[:upper:]' '[:lower:]' | awk '{print $1}' || true)"
    case "$st" in
      done|complete|completed|abandoned)
        closed_plans=$((closed_plans + 1))
        closed_list="${closed_list}    - $(basename "$f") ($st)"$'\n' ;;
    esac
  done <<EOF
$(find "$PLANS" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
EOF
fi
if [ "$closed_plans" -gt 0 ]; then
  add "- ⚠️ closed plans still in Plans/: ${closed_plans} (status done/complete/abandoned) — archive to Plans-archive/ + remove"
  inc
else
  add "- ok closed plans in Plans/: 0"
fi

# ── Check 3: ledgers over cap ─────────────────────────────────────────────────
i=0
while [ "$i" -lt "${#LEDGER_PATHS[@]}" ]; do
  rel="${LEDGER_PATHS[$i]}"
  cap="${LEDGER_CAPS[$i]}"
  i=$((i + 1))
  f="$ROOT/$rel"
  if [ -f "$f" ]; then
    lines="$(grep -cvE '^[[:space:]]*$' "$f" 2>/dev/null || echo 0)"
    if [ "$lines" -gt "$cap" ]; then
      add "- ⚠️ ledger over cap: ${rel} — ${lines} lines (cap ${cap}) — prune at check-in"
      inc
    else
      add "- ok ledger: ${rel} — ${lines} lines (cap ${cap})"
    fi
  fi
done

# ── Check 4: garbage files (zero-byte, double-dot, stray Users/ tree) ─────────
garbage=0
garbage_list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  garbage=$((garbage + 1))
  garbage_list="${garbage_list}    - ${f#"$ROOT"/} (zero-byte)"$'\n'
done <<EOF
$(find "$ROOT" \( -name .obsidian -o -name .smart-env -o -name .git \) -prune -o -type f -name '*.md' -size 0 -print 2>/dev/null)
EOF
while IFS= read -r f; do
  [ -n "$f" ] || continue
  garbage=$((garbage + 1))
  garbage_list="${garbage_list}    - ${f#"$ROOT"/} (double-dot)"$'\n'
done <<EOF
$(find "$ROOT" \( -name .obsidian -o -name .smart-env -o -name .git \) -prune -o -type f -name '*..md' -print 2>/dev/null)
EOF
if [ -d "$ROOT/Users" ]; then
  garbage=$((garbage + 1))
  garbage_list="${garbage_list}    - Users/ (stray absolute-path tree)"$'\n'
fi
if [ "$garbage" -gt 0 ]; then
  add "- ⚠️ garbage files: ${garbage} (zero-byte / double-dot / stray path) — delete"
  inc
else
  add "- ok garbage files: 0"
fi

# ── Check 5: stale last_verified tally (informational) ────────────────────────
stale_verified=0
now="$(now_epoch)"
horizon=$(( STALE_VERIFIED_DAYS * 86400 ))
while IFS= read -r f; do
  [ -n "$f" ] || continue
  lv="$(grep -m1 -E '^last_verified:[[:space:]]*' "$f" 2>/dev/null | sed -e 's/^last_verified:[[:space:]]*//' -e 's/["'\'']//g' | tr -d '\r' | awk '{print $1}' || true)"
  [ -n "$lv" ] || continue
  # Parse YYYY-MM-DD → epoch (GNU `date -d` vs BSD `date -j -f`).
  lv_epoch="$(date -d "$lv" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$lv" +%s 2>/dev/null || echo '')"
  [ -n "$lv_epoch" ] || continue
  if [ $(( now - lv_epoch )) -gt "$horizon" ]; then
    stale_verified=$((stale_verified + 1))
  fi
done <<EOF
$(find "$ROOT/Decisions" "$ROOT/Patterns" "$ROOT/Mistakes" "$ROOT/Context" -type f -name '*.md' 2>/dev/null)
EOF
add "- info stale last_verified (>${STALE_VERIFIED_DAYS}d): ${stale_verified} notes"

# ── Emit ──────────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "entry" ]; then
  [ "$alarms" -eq 0 ] && exit 0   # clean → append nothing
  ts="$(date '+%Y-%m-%d %H:%M')"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  printf '### %s · vault hygiene · %s\n' "$ts" "$host"
  printf -- '- **Decision:** dispose of %d vault-hygiene alarm(s) below (drain proposed; check-in disposes).\n' "$alarms"
  printf -- '- **Findings:**\n'
  printf '%s' "$FINDINGS" | sed 's/^/  /'
  [ -n "$closed_list" ] && { printf -- '  - closed plans:\n'; printf '%s' "$closed_list"; }
  [ -n "$garbage_list" ] && { printf -- '  - garbage:\n'; printf '%s' "$garbage_list"; }
  printf -- '- **Status:** open\n'
  exit 0
fi

# Default: human-readable report.
echo "=== vault hygiene report ($ROOT) ==="
printf '%s' "$FINDINGS"
[ -n "$closed_list" ] && { echo "  closed plans still resident:"; printf '%s' "$closed_list"; }
[ -n "$garbage_list" ] && { echo "  garbage files:"; printf '%s' "$garbage_list"; }
echo "---"
if [ "$alarms" -gt 0 ]; then
  echo "ALARM: $alarms"
else
  echo "OK"
fi
exit 0
