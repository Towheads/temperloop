#!/usr/bin/env bash
#
# vault_hygiene_report.sh — detect-and-propose vault-maintenance probe.
#
# A periodic hygiene DETECTOR for the knowledge-store vault: nothing else
# alarms on drift, so silent pile-ups (162 _inbox stubs / 18 MB before anyone
# noticed — foundation #958) go unseen. This script only REPORTS by default;
# it never deletes vault content, and it mutates only under the explicit
# --heal opt-in, and then only the mechanically-safe class (see § Auto-heal
# below). /tidy runs it and appends alarms to a review surface; check-in
# disposes everything else. Drain proposes, check-in disposes (foundation
# #959).
#
# ── Checks (over the vault root) ────────────────────────────────────────────
# Housekeeping checks (foundation #959):
#   1. _inbox stubs        — count + oldest age; ALARM if >20 stubs or >48h.
#   2. closed plans        — Plans/*.md with status done|complete|abandoned
#                             still resident (should be archived+removed);
#                             ALARM if >0.
#   3. ledgers over cap    — named ledgers over a size/line cap (constants
#                             below).
#   4. garbage files       — zero-byte *.md, `..md` double-dot typos, stray
#                             `Users/`-tree paths; ALARM if any.
#   5. stale last_verified — count of provenance notes older than the
#                             staleness horizon (informational tally, not an
#                             alarm).
#
# Structural lints (temperloop#230, epic temperloop#226 — ADR §2.2):
#   6. folder allowlist    — a top-level store folder outside the ADR §2.2
#                             allowlist (ALLOWED_TOP_FOLDERS below). A
#                             case-only mismatch of an allowed name (e.g.
#                             `decisions/` vs `Decisions/`) is the one
#                             mechanically-safe auto-heal class this script
#                             implements (see § Auto-heal); anything else is
#                             propose-only.
#   7. one-file-directory  — a directory (nested below a top-level folder)
#                             holding exactly one file, outside the ADR
#                             schema's known nested substructure
#                             (SCHEMA_NESTED_DIRS below, e.g. Sessions/_inbox).
#                             Propose-only — flattening is a judgment call.
#   8. naming drift         — a note filename in a note-per-topic folder
#                             (NAMING_LINT_FOLDERS below) that doesn't match
#                             the `<project> - <title>` convention. Propose-
#                             only — the correct project/title split is a
#                             judgment call.
#   9. stale plan           — a Plans/ note with frontmatter `status:`
#                             draft|approved whose mtime is older than
#                             STALE_PLAN_DAYS. Propose-only.
#  10. kind-misfile          — a dated or verdict-shaped title sitting in
#                             Patterns/ (heuristic: a `YYYY-MM-DD…` filename
#                             prefix, or `verdict`/`decision` in the title) —
#                             usually really a Decision/Investigation.
#                             Propose-only.
#
# Repeat-mistake detector (temperloop#234 — ADR §2.6):
#  11. repeat-mistake        — a NEW Session friction ledger row (dated within
#                             FRICTION_RECENT_DAYS) whose text shares enough
#                             vocabulary with an existing Mistakes/ note's
#                             title + `trigger:` frontmatter is flagged as a
#                             retrieval failure — a recurrence despite an
#                             existing note. Propose-only. ALARM if any.
#
# `Personal/` is NEVER flagged by any lint above (structural or housekeeping)
# — it is in the folder allowlist outright, and every recursive walk below
# prunes it explicitly (case-insensitively), so nothing nested under it is
# ever swept into a finding, healed, or counted.
#
# ── Additive check-registration seam (temperloop#230) ──────────────────────
# Every check is a self-contained `check_<name>()` function that appends its
# own finding(s) via `add`/`inc`, immediately followed by one
# `register_check check_<name>` call. The run loop near the bottom of this
# file (`for fn in "${CHECKS[@]}"; do "$fn"; done`) is generic — it never
# changes. Adding a new check is therefore a PURELY ADDITIVE block: define
# the function, register it, done — no renumbering, no shared-line edits, no
# touching the emit/arg-parse machinery. This is the seam four later plan
# items (repeat-mistake-detector, ks-read-surfacing, heat-score-review-queue,
# vault-readpath-lints) each add a check through, in parallel branches. A
# template:
#
#   check_my_new_lint() {
#     local count=0
#     # ... walk $ROOT, call `add "- ⚠️ ..."` + `inc` per finding, or a single
#     # `add "- ok my-new-lint: 0"` when clean ...
#   }
#   register_check check_my_new_lint
#
# ── Auto-heal (temperloop#230) ──────────────────────────────────────────────
# Restricted to the mechanically-safe class ONLY, opt-in via --heal (the
# default report/entry run never mutates the vault, preserving this script's
# original never-mutates contract for anyone not passing --heal):
#   - naming-case normalization + wikilink retarget — the ONLY heal this
#     script performs: a top-level folder whose name case-insensitively
#     matches an ADR §2.2 allowlist entry but not exactly (e.g. `decisions/`
#     vs `Decisions/`) is renamed to the canonical case, and every literal
#     `[[<old>/` wikilink reference across the store is rewritten to
#     `[[<new>/` in the same pass — a mechanical, unambiguous, reversible
#     rename with no content judgment involved.
# Everything else this script finds — an unrecognized top-level folder, a
# one-file directory, naming drift with no unambiguous split, a stale plan,
# a kind-misfiled Pattern — is judgment-shaped (moving/renaming/reclassifying
# content requires a human call) and stays propose-only even with --heal.
# NOTHING this script does ever deletes a file or directory, healed or not.
# ("Unambiguous provenance backfill" — the third safe-class member named by
# the epic contract — is not applicable to any lint this script owns; that
# class is already implemented by /tidy's own Provenance-audit pass over
# Decisions/Patterns/Mistakes/Context.)
#
# Usage:
#   vault_hygiene_report.sh [--root DIR] [--format entry] [--heal]
#     --root DIR       vault root (default: the knowledge_store seam's ks_root
#                      — KNOWLEDGE_STORE_ROOT if set, else its generic
#                      per-user default; see knowledge_store.sh)
#     --format entry   print a ready-to-append `### … Status: open` block IFF
#                      any alarm fires (nothing when clean); default prints a
#                      human-readable report + trailing `ALARM: <n>` / `OK`.
#     --heal           perform the mechanically-safe auto-heal (folder
#                      naming-case normalization + wikilink retarget) for any
#                      finding that qualifies, alongside the normal report.
#                      Everything else still only reports. Default: off.
#
# Exit 0 always when the vault is reachable (a report is not a failure); exit 0
# with a one-line notice when the root is absent (a stranger's checkout has no
# vault — never fail the drain/CI). Exit 2 only on a usage error.
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) with BSD-vs-GNU
# stat/date fallbacks, so it runs on the macOS dev shell as well as Linux CI.
#
# shellcheck disable=SC2329,SC2317
# ^ File-wide, both codes for ONE false positive: every check_*/helper
# function here is invoked INDIRECTLY, through the register_check →
# CHECKS[] → `"$_hyg_fn"` dispatch loop (see § Additive check-registration
# seam). Newer shellcheck (≥0.10) reports that as function-level SC2329
# ("never invoked"); older shellcheck (0.9.x, ubuntu-latest CI's apt build)
# predates the SC2329 split and instead emits per-command SC2317
# ("unreachable") inside the same functions — both must be disabled for the
# gate to pass on both toolchains (same paired disable as
# workflows/scripts/build/archive-plan.sh uses for its indirectly-invoked
# populate_plan). Details of the reproduced false positive: shellcheck's
# "never invoked" reachability pass tracks that loop fine
# on its own, but loses the thread once the top-level `if/exit` emit logic
# after it is also present (confirmed false-positive, reproduced in
# isolation: a minimal register_check+for-loop script stays clean until a
# trailing top-level if/exit is appended, at which point EVERY function in
# the file — including ones called by ordinary direct literal call sites
# elsewhere — gets flagged). Real dead code is still caught by every other
# check this script's shellcheck gate runs.

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

# ── Structural-lint tunables (temperloop#230) ───────────────────────────────
# ADR §2.2 top-level store-folder allowlist. CLEARLY-MARKED, easily-edited —
# an overlay may extend this array (append more allowed top-level names)
# without touching a kernel line. `Personal/` is in this list, so it is never
# a folder-allowlist violation on its own; every recursive lint below ALSO
# prunes it explicitly, so nothing nested under it is ever swept in either.
ALLOWED_TOP_FOLDERS=(
  Plans Decisions Patterns Mistakes Context Sessions Priorities Controls
  Pipeline Investigations Projects Personal
)
# Folders the one-file-directory lint (check 7) must NOT flag even though
# they nest below a top-level folder and may legitimately hold exactly one
# file (e.g. a vault that has just started draining) — known ADR schema
# substructure, not drift. Paths are relative to the store root.
SCHEMA_NESTED_DIRS=(
  "Sessions/_inbox"
)
# Note-per-topic folders the naming-drift lint (check 8) sweeps for the
# `<project> - <title>.md` convention. Sessions/ (its own `<date>-<time>-
# <project>-<id8>.md` prefix convention) and Personal/ are deliberately
# excluded.
NAMING_LINT_FOLDERS=(Decisions Patterns Mistakes Plans)
STALE_PLAN_DAYS=30   # Plans/ note with status draft|approved untouched this long -> alarm

# ── Arg parse ─────────────────────────────────────────────────────────────────
ROOT="$(ks_root)"
FORMAT="report"
HEAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)   ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --heal)   HEAL=1; shift ;;
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
# Epoch mtime of a file (BSD `stat -f %m` vs GNU `stat -c %Y`). The dialect is
# feature-detected ONCE, up front — a `stat -f %m || stat -c %Y` fallback
# chain is NOT portable, because GNU stat does not fail cleanly on the BSD
# spelling: there `-f` means --file-system (a boolean, not a format flag), so
# `stat -f %m FILE` prints multi-line filesystem status for FILE on stdout
# and exits 1 (the literal `%m` operand doesn't exist), and the `||` fallback
# then APPENDS the real epoch to that garbage. The poisoned value lands in
# integer comparisons ("integer expression expected" spam) and, under
# `set -u`, kills the whole run at the first `$(( now - mt ))` (Linux CI,
# temperloop#250). Detection probe: only GNU stat accepts `-c`; BSD stat
# exits non-zero on it with no stdout.
if stat -c %Y . >/dev/null 2>&1; then
  _hyg_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }   # GNU coreutils
else
  _hyg_stat_mtime() { stat -f %m "$1" 2>/dev/null; }   # BSD/macOS
fi
# Regression guard for the above: whatever the dialect emitted, never let a
# non-numeric value reach a `[ -lt ]`/`$(( ))` caller — coerce to 0 instead.
file_mtime() {
  local m
  m="$(_hyg_stat_mtime "$1")" || m=0
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}
# Current epoch without Date.now()-style pitfalls — plain `date` is fine here.
now_epoch() { date +%s; }

# Excludes for whole-vault walks: never descend Obsidian internals, the
# embedding store (thousands of files — CLAUDE.md forbids bulk-grepping it),
# or Personal/ (never flagged by any lint — case-insensitive so `personal/`
# is caught too). The prune expression is inlined at each `find` (see below)
# rather than held in a word-split variable, so no unquoted expansion is
# needed.

alarms=0
inc() { alarms=$((alarms + 1)); }

# Findings accumulate as lines; entry-format wraps them, report-format lists them.
FINDINGS=""
add()  { FINDINGS="${FINDINGS}$1"$'\n'; }

# ── Additive check-registration seam ────────────────────────────────────────
# See the header comment (§ Additive check-registration seam) for the
# contract. This array + register_check + the run loop near the bottom of
# the file are the ONLY shared machinery; nothing below should ever need to
# change when a new check is added.
CHECKS=()
register_check() { CHECKS+=("$1"); }

# ── Check 1: _inbox stubs ─────────────────────────────────────────────────────
check_inbox() {
  local INBOX="$ROOT/Sessions/_inbox" stub_count=0 oldest_age_h=0 now oldest_epoch f m
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
}
register_check check_inbox

# ── Check 2: closed plans still resident in Plans/ ────────────────────────────
check_closed_plans() {
  local PLANS="$ROOT/Plans" closed_plans=0 f st
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
          add "- ⚠️ closed plan still in Plans/: $(basename "$f") ($st) — archive to Plans-archive/ + remove"
          ;;
      esac
    done <<EOF
$(find "$PLANS" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
EOF
  fi
  if [ "$closed_plans" -eq 0 ]; then
    add "- ok closed plans in Plans/: 0"
  else
    add "- ⚠️ closed plans still in Plans/: ${closed_plans} (status done/complete/abandoned)"
    inc
  fi
}
register_check check_closed_plans

# ── Check 3: ledgers over cap ─────────────────────────────────────────────────
check_ledger_caps() {
  local i=0 rel cap f lines
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
}
register_check check_ledger_caps

# ── Check 4: garbage files (zero-byte, double-dot, stray Users/ tree) ─────────
check_garbage() {
  local garbage=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    garbage=$((garbage + 1))
    add "- ⚠️ garbage: ${f#"$ROOT"/} (zero-byte) — delete"
  done <<EOF
$(find "$ROOT" \( -iname .obsidian -o -iname .smart-env -o -iname .git -o -iname Personal \) -prune -o -type f -name '*.md' -size 0 -print 2>/dev/null)
EOF
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    garbage=$((garbage + 1))
    add "- ⚠️ garbage: ${f#"$ROOT"/} (double-dot) — delete"
  done <<EOF
$(find "$ROOT" \( -iname .obsidian -o -iname .smart-env -o -iname .git -o -iname Personal \) -prune -o -type f -name '*..md' -print 2>/dev/null)
EOF
  if [ -d "$ROOT/Users" ]; then
    garbage=$((garbage + 1))
    add "- ⚠️ garbage: Users/ (stray absolute-path tree) — delete"
  fi
  if [ "$garbage" -eq 0 ]; then
    add "- ok garbage files: 0"
  else
    add "- ⚠️ garbage files: ${garbage} total (zero-byte / double-dot / stray path)"
    inc
  fi
}
register_check check_garbage

# ── Check 5: stale last_verified tally (informational) ────────────────────────
check_stale_verified() {
  local stale_verified=0 now horizon f lv lv_epoch
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
}
register_check check_stale_verified

# ── Structural-lint helpers (folder-allowlist / heal) ───────────────────────
# name -> 0 (allowed, exact case) if $1 is exactly one of ALLOWED_TOP_FOLDERS.
_hyg_is_allowed_folder() {
  local n="$1" a
  for a in "${ALLOWED_TOP_FOLDERS[@]}"; do
    [ "$n" = "$a" ] && return 0
  done
  return 1
}
# name -> prints the canonical allowlist entry on stdout + returns 0 iff $1
# matches an allowlist entry case-INsensitively (exact-case matches are
# handled by _hyg_is_allowed_folder before this is ever called). Returns 1
# with no output if $1 doesn't case-insensitively match anything allowed.
_hyg_canonical_folder_case() {
  local n_lc a
  n_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for a in "${ALLOWED_TOP_FOLDERS[@]}"; do
    if [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "$n_lc" ]; then
      printf '%s' "$a"
      return 0
    fi
  done
  return 1
}
# rel-path relative to $SCHEMA_NESTED_DIRS -> 0 iff $1 is (or is nested under)
# a known ADR schema nested directory (e.g. Sessions/_inbox).
_hyg_is_schema_nested() {
  local rel="$1" s
  for s in "${SCHEMA_NESTED_DIRS[@]}"; do
    [ "$rel" = "$s" ] && return 0
    case "$rel" in "$s"/*) return 0 ;; esac
  done
  return 1
}
# old new -> literal in-place rewrite of every `[[<old>/` wikilink reference
# to `[[<new>/`, across every note under $ROOT (excluding the same prunes as
# every other whole-vault walk here). Portable: writes to a sibling temp file
# and renames into place rather than relying on BSD-vs-GNU `sed -i` flag
# differences (same atomic-replace idiom as knowledge_store.sh's plain-files
# write backend).
_hyg_retarget_wikilinks() {
  local old="$1" new="$2" f tmp
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qF "[[${old}/" "$f" 2>/dev/null; then
      tmp="$(mktemp "${f}.XXXXXX")"
      sed "s#\\[\\[${old}/#[[${new}/#g" "$f" > "$tmp" && mv "$tmp" "$f"
    fi
  done <<EOF
$(find "$ROOT" \( -iname .obsidian -o -iname .smart-env -o -iname .git -o -iname Personal \) -prune -o -type f -name '*.md' -print 2>/dev/null)
EOF
}

# ── Check 6: folder allowlist (ADR §2.2) ─────────────────────────────────────
check_folder_allowlist() {
  local bad=0 d name canon
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      .*) continue ;;   # dot-dirs (.obsidian, .smart-env, .git) are vault internals, not user content
    esac
    case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
      personal) continue ;;   # Personal/ is never flagged by any lint, any case
    esac
    _hyg_is_allowed_folder "$name" && continue
    if canon="$(_hyg_canonical_folder_case "$name")"; then
      bad=$((bad + 1))
      # Collision guard: `[ -e "$ROOT/$canon" ]` alone is not enough — on a
      # case-INsensitive, case-preserving filesystem (APFS's default, the
      # macOS dev shell) it is ALWAYS true once `$ROOT/$name` itself exists,
      # since the two paths resolve to the same directory entry. `-ef`
      # (same device+inode) tells a genuine collision (a real, different
      # directory already at the canonical name) apart from that same-entry
      # case, so heal still fires correctly on a case-sensitive filesystem
      # (Linux CI) as well as a case-insensitive one (macOS).
      if [ "$HEAL" -eq 1 ] && { [ ! -e "$ROOT/$canon" ] || [ "$ROOT/$name" -ef "$ROOT/$canon" ]; }; then
        mv "$ROOT/$name" "$ROOT/$canon"
        _hyg_retarget_wikilinks "$name" "$canon"
        add "- healed: folder case ${name}/ → ${canon}/ (naming-case normalization + wikilink retarget)"
      else
        add "- ⚠️ allowlist: ${name}/ — case mismatch of ADR §2.2 folder ${canon}/ (safe to auto-heal: naming-case normalization — run with --heal)"
        inc
      fi
      continue
    fi
    bad=$((bad + 1))
    add "- ⚠️ allowlist: ${name}/ — not in the ADR §2.2 top-level folder allowlist (propose-only: move its contents, rename, or extend the allowlist)"
    inc
  done <<EOF
$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
EOF
  [ "$bad" -eq 0 ] && add "- ok folder allowlist: 0 violations"
  return 0
}
register_check check_folder_allowlist

# ── Check 7: one-file-directory ───────────────────────────────────────────────
check_one_file_dir() {
  local count=0 d filecount rel
  # NOTE: no -mindepth here — combining -mindepth with -prune is unreliable
  # across find implementations (confirmed: BSD find on macOS silently fails
  # to prune when -mindepth is also present, even though the identical prune
  # clause works fine without it — GNU find on Linux CI does not share this
  # quirk, but the exclusion must work on both). Depth (nested-only, i.e.
  # below a top-level folder) is filtered in the shell loop below instead via
  # a plain slash-count check on the relative path.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$d" = "$ROOT" ] && continue
    rel="${d#"$ROOT"/}"
    case "$rel" in
      */*) ;;              # nested (depth >= 2) — eligible
      *) continue ;;       # a top-level folder itself — check_folder_allowlist's lane, not this one
    esac
    _hyg_is_schema_nested "$rel" && continue
    filecount="$(find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$filecount" -eq 1 ]; then
      count=$((count + 1))
      add "- ⚠️ one-file-directory: ${rel}/ — holds a single file outside the ADR schema (propose-only: flatten, or confirm the subfolder is intentional)"
      inc
    fi
  done <<EOF
$(find "$ROOT" \( -iname .obsidian -o -iname .smart-env -o -iname .git -o -iname Personal \) -prune -o -type d -print 2>/dev/null | sort)
EOF
  [ "$count" -eq 0 ] && add "- ok one-file-directory: 0"
  return 0
}
register_check check_one_file_dir

# ── Check 8: naming drift ─────────────────────────────────────────────────────
check_naming_drift() {
  local count=0 d dir f base rel
  for d in "${NAMING_LINT_FOLDERS[@]}"; do
    dir="$ROOT/$d"
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base="$(basename "$f" .md)"
      case "$base" in
        *" - "*) continue ;;   # matches the `<project> - <title>` convention
      esac
      count=$((count + 1))
      rel="${f#"$ROOT"/}"
      add "- ⚠️ naming: ${rel} — filename doesn't match the \`<project> - <title>\` convention (propose-only: confirm the right project/title split before renaming)"
      inc
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
EOF
  done
  [ "$count" -eq 0 ] && add "- ok naming: 0 drift"
  return 0
}
register_check check_naming_drift

# ── Check 9: stale plan (draft/approved untouched >STALE_PLAN_DAYS) ─────────
check_stale_plan() {
  local count=0 dir="$ROOT/Plans" f st mt now cutoff
  now="$(now_epoch)"
  cutoff=$((STALE_PLAN_DAYS * 86400))
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      st="$(grep -m1 -iE '^status:[[:space:]]*' "$f" 2>/dev/null | sed -e 's/^[Ss]tatus:[[:space:]]*//' -e 's/["'\'']//g' | tr -d '\r' | tr '[:upper:]' '[:lower:]' | awk '{print $1}' || true)"
      case "$st" in
        draft|approved)
          mt="$(file_mtime "$f")"
          if [ $(( now - mt )) -gt "$cutoff" ]; then
            count=$((count + 1))
            add "- ⚠️ stale plan: $(basename "$f") (status ${st}, untouched >${STALE_PLAN_DAYS}d) — propose-only: confirm still active or archive"
            inc
          fi
          ;;
      esac
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
EOF
  fi
  [ "$count" -eq 0 ] && add "- ok stale plans (draft/approved >${STALE_PLAN_DAYS}d): 0"
  return 0
}
register_check check_stale_plan

# ── Check 10: kind-misfile heuristic (dated/verdict-shaped titles in Patterns/) ──
check_kind_misfile() {
  local count=0 dir="$ROOT/Patterns" f base rel
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base="$(basename "$f" .md)"
      rel="${f#"$ROOT"/}"
      case "$base" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
          count=$((count + 1))
          add "- ⚠️ kind-misfile: ${rel} — dated title in Patterns/ (propose-only: likely a Decision/Investigation, confirm before moving)"
          inc
          continue
          ;;
      esac
      case "$base" in
        *[Vv]erdict*|*[Dd]ecision*)
          count=$((count + 1))
          add "- ⚠️ kind-misfile: ${rel} — verdict-shaped title in Patterns/ (propose-only: likely a Decision/Investigation, confirm before moving)"
          inc
          ;;
      esac
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
EOF
  fi
  [ "$count" -eq 0 ] && add "- ok kind-misfile (Patterns/): 0"
  return 0
}
register_check check_kind_misfile

# ── Check 11: repeat-mistake detector (temperloop#234 — ADR §2.6) ───────────
# ADR §2.6 names repeat-mistake rate ≈ 0 as the headline value metric for
# "the vault works" — a friction row that recurs despite an existing
# Mistakes/ note is exactly the failure that metric tracks, so this check
# cross-references NEW friction-ledger rows against Mistakes/ and flags a
# match as a retrieval failure. "New" = dated within FRICTION_RECENT_DAYS of
# now, the same recency-window shape STALE_PLAN_DAYS/STALE_VERIFIED_DAYS
# already use elsewhere in this script, rather than re-scanning the ledger's
# whole history every run (a row older than the window already went through
# at least one prior check-in/tidy cycle — not this check's concern).
# Matching is deliberately simple and mechanical: lowercase + split on
# non-alnum, drop tokens shorter than 4 chars and a small stopword list, then
# count tokens shared between the row's text and a Mistakes/ note's title +
# `trigger:` frontmatter (scalar `trigger: a, b` or YAML-list form); >=2
# shared tokens is a match (1 alone is too weak — every row and every note
# share the project name, e.g. "temperloop", so a 1-token floor would flag on
# that alone). Propose-only: never edits the ledger or Mistakes/. Graceful
# no-op when the ledger or Mistakes/ is absent (a bare kernel checkout has
# neither).
FRICTION_RECENT_DAYS=14
_HYG_STOPWORDS=" this that with from have were what when where which should using used just been also into over than then still very more your "

# YYYY-MM-DD -> epoch (GNU `date -d` vs BSD `date -j -f`); empty on failure.
_hyg_date_to_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null || echo ''
}
# string -> space-separated lowercase alnum tokens, len>=4, stopwords dropped
_hyg_tokenize() {
  local s t out=""
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ')"
  for t in $s; do
    [ "${#t}" -ge 4 ] || continue
    case "$_HYG_STOPWORDS" in *" $t "*) continue ;; esac
    out="$out $t"
  done
  printf '%s' "$out"
}
# set_a set_b (space-separated token lists) -> count of $1's tokens also in $2
_hyg_token_overlap() {
  local a match=0
  for a in $1; do
    case " $2 " in *" $a "*) match=$((match + 1)) ;; esac
  done
  printf '%s' "$match"
}
# Mistakes/<file>.md -> its title + `trigger:` frontmatter tokens (scalar
# `trigger: a, b, c` or YAML-list `trigger:\n  - a\n  - b`).
_hyg_mistake_tokens() {
  local f="$1" fm title trig trig_list
  title="$(basename "$f" .md)"
  fm="$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$f" 2>/dev/null)"
  trig="$(printf '%s\n' "$fm" | grep -im1 '^trigger:' | sed -e 's/^[Tt]rigger:[[:space:]]*//' -e 's/["'\'']//g')"
  trig_list="$(printf '%s\n' "$fm" | awk '/^trigger:[[:space:]]*$/{f=1;next} f && /^[[:space:]]+-/{print;next} {f=0}')"
  _hyg_tokenize "$title $trig $trig_list"
}

check_repeat_mistake() {
  local LEDGER="$ROOT/Context/Session friction ledger.md" MISTAKES="$ROOT/Mistakes"
  local count=0 checked=0 now cutoff line row rdate rrest repoch rtoks
  local mf mtoks overlap
  if [ ! -f "$LEDGER" ] || [ ! -d "$MISTAKES" ]; then
    add "- ok repeat-mistake: 0 (no friction ledger or no Mistakes/)"
    return 0
  fi
  now="$(now_epoch)"
  cutoff=$((FRICTION_RECENT_DAYS * 86400))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    row="${line#- }"
    rdate="${row%% *}"
    rrest="${row#"$rdate" }"
    rrest="${rrest#"· "}"
    [ -n "$rdate" ] || continue
    repoch="$(_hyg_date_to_epoch "$rdate")"
    [ -n "$repoch" ] || continue
    [ $(( now - repoch )) -gt "$cutoff" ] && continue
    checked=$((checked + 1))
    rtoks="$(_hyg_tokenize "$rrest")"
    [ -n "$rtoks" ] || continue
    while IFS= read -r mf; do
      [ -n "$mf" ] || continue
      mtoks="$(_hyg_mistake_tokens "$mf")"
      [ -n "$mtoks" ] || continue
      overlap="$(_hyg_token_overlap "$rtoks" "$mtoks")"
      if [ "$overlap" -ge 2 ]; then
        add "- ⚠️ repeat-mistake: ${rdate} — ${rrest} — matches Mistakes/${mf#"$ROOT"/} (retrieval failure: recurrence despite an existing note)"
        inc
        count=$((count + 1))
        break
      fi
    done <<EOF
$(find "$MISTAKES" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
EOF
  done <<EOF
$(grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2} · ' "$LEDGER" 2>/dev/null)
EOF
  [ "$count" -eq 0 ] && add "- ok repeat-mistake: 0 (${checked} new row(s) within ${FRICTION_RECENT_DAYS}d checked)"
  return 0
}
register_check check_repeat_mistake

# ── Run every registered check (generic — never changes when adding a check) ──
for _hyg_fn in "${CHECKS[@]}"; do
  "$_hyg_fn"
done

# ── Emit ──────────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "entry" ]; then
  [ "$alarms" -eq 0 ] && exit 0   # clean → append nothing
  ts="$(date '+%Y-%m-%d %H:%M')"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  printf '### %s · vault hygiene · %s\n' "$ts" "$host"
  printf -- '- **Decision:** dispose of %d vault-hygiene alarm(s) below (drain proposed; check-in disposes).\n' "$alarms"
  printf -- '- **Findings:**\n'
  printf '%s' "$FINDINGS" | sed 's/^/  /'
  printf -- '- **Status:** open\n'
  exit 0
fi

# Default: human-readable report.
echo "=== vault hygiene report ($ROOT) ==="
printf '%s' "$FINDINGS"
echo "---"
if [ "$alarms" -gt 0 ]; then
  echo "ALARM: $alarms"
else
  echo "OK"
fi
exit 0
