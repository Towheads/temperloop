#!/usr/bin/env bash
#
# check-prerename-leak-guard.sh — pre-rename identifier leak gate
# (temperloop#433, gate-sweep item; depends on the foundation->temperloop
# rename, temperloop#165 / PR #487).
#
# The rename left every stranger-facing `foundation` name working through a
# documented v0.17.0 read-old window, plus a small number of paths the
# rename item deliberately did NOT migrate at all (allowlisted as legacy).
# THIS gate is what keeps that a closed, reviewed set: it scans the same
# stranger-surface file set the sibling scrubs already cover
# (list-kernel-set.sh's `kernel` class — see check-personal-token-denylist.sh)
# for pre-rename identifier SHAPES and fails on any occurrence that is not
# one of the specific tokens/leaves the rename item's own verdict table
# (prerename-leak-verdicts.tsv, sibling file) already reviewed and recorded.
# A brand-new `FOUNDATION_*` env var, or a brand-new leaf under a legacy
# `.../foundation/` XDG subdir, therefore can't silently reappear without
# either being added to that table (a reviewed decision) or tripping this
# gate red.
#
# WHAT IS SCANNED (four identifier shapes):
#   1. `FOUNDATION_<NAME>` env-var identifiers — looked up by EXACT token
#      against prerename-leak-verdicts.tsv's `env` rows. An unknown token
#      is a violation (a new, unreviewed FOUNDATION_-prefixed knob).
#   2. `.foundation/<leaf>` (any leaf) — the committed per-repo compat dir
#      (verdict-table row "Committed .foundation/ per-repo dir": migrate,
#      read-old). This is the compat shim's OWN intentional legacy literal
#      in totality (the rename's whole point was read-old across every leaf
#      under this dir, not an enumerable closed set) — matched but ALWAYS
#      allowed, never looked up.
#   3. `bin/foundation` — the CLI compat shim's own binary path. Same
#      "compat shim's own intentional legacy literal" carve-out as #2:
#      always allowed, never looked up.
#   4. `foundation/<leaf>` (NOT dot-prefixed — see #2), on a line that ALSO
#      carries an XDG-home-shaped anchor (`XDG_*_HOME`, `~/.config`,
#      `~/.cache`, `~/.local/share`, `~/.local/state`, `~/.local/bin`, or the
#      `$HOME/.<xdg-dir>` spelling of any of those) — i.e. an XDG-rooted
#      machine-state/config/data legacy subdir leaf (boards.conf, knowledge,
#      agent-heartbeat, the hook-state family, ...). Looked up by EXACT leaf
#      against prerename-leak-verdicts.tsv's `path-leaf` rows. An unknown
#      leaf is a violation.
#
#      The anchor requirement matters: this repo's docs/scripts ALSO
#      routinely say `foundation/<subdir>` to mean a path INSIDE the
#      separate, still-real, personal overlay/build repo that is itself
#      named `foundation` (e.g. `foundation/workflows/...`,
#      `~/dev/foundation/meta/sessions/archive/`, `Projects/foundation/...`
#      vault paths, knob-registry.tsv's own `FOUNDATION` checkout-root knob)
#      — a completely different, currently-valid identifier that happens to
#      share the old kernel name, not a pre-rename identifier of THIS
#      kernel at all. Requiring an XDG-home anchor on the same line is what
#      tells the two apart without an unbounded prose-classification job.
#
# What is deliberately NOT scanned: bare CLI-invocation prose (`` `foundation` ``,
# "foundation <sub>", "foundation eject") and bare historical issue references
# ("foundation #798") — these are narrative documentation of the compat
# window's existence, not a machine-checkable identifier surface, and (per
# the verdict table's own scope) the rename item's contract-surface
# enumeration is about paths/env-vars, not prose. A bare
# `${XDG_STATE_HOME:-...}/foundation` mention with NO further leaf (the hook
# state-family's shared base dir, e.g. claude/hooks/*-guard.sh) also isn't
# matched by shape #4 (which requires a trailing `/leaf`) — it needs no
# lookup because it carries no distinguishing NEW identifier at all; it's
# the same already-allowlisted shared base dir regardless of which file
# references it. A markdown-wrapped identifier split across two physical
# source lines (rare; docs/features/knowledge-store.md is one instance) is
# also invisible to this line-oriented scan — an accepted, fail-open gap,
# not a design goal.
#
# EXEMPTIONS: this gate honours its OWN wholesale file-exempt list
# (prerename-leak-exempt-files.txt, sibling — today just this gate's own
# fixture-replay test) AND, deliberately DRY with the sibling scrub, the
# personal-token-denylist's exempt list (personal-token-denylist-exempt-files.txt)
# — several of those board/build fixture-replay tests embed full GitHub URLs
# for the real, still-existing `Towheads/foundation` build repo (board 4),
# e.g. ".../repos/Towheads/foundation/issues/145", which incidentally
# contains the substring `foundation/issues` and would otherwise false-positive
# shape #4 above even though it has nothing to do with this kernel's own
# pre-rename identity. See that file's header for the per-file rationale.
#
# Usage:
#   check-prerename-leak-guard.sh [--root DIR]
#   (called by `make test-kernel-prerename`)
#
# Env overrides (fixture-driven tests):
#   KERNEL_MANIFEST_ROOT, KERNEL_MANIFEST_FILE, PRERENAME_VERDICTS_FILE,
#   PRERENAME_EXEMPT_FILE, KERNEL_DENYLIST_EXEMPT_FILE
#
# Kept bash-3.2 friendly (macOS default shell) — no mapfile/associative arrays.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT}"
: "${PRERENAME_VERDICTS_FILE:=$SCRIPT_DIR/prerename-leak-verdicts.tsv}"
: "${PRERENAME_EXEMPT_FILE:=$SCRIPT_DIR/prerename-leak-exempt-files.txt}"
: "${KERNEL_DENYLIST_EXEMPT_FILE:=$SCRIPT_DIR/personal-token-denylist-exempt-files.txt}"

if [[ ! -f "$PRERENAME_VERDICTS_FILE" ]]; then
  echo "check-prerename-leak-guard: verdict table not found at $PRERENAME_VERDICTS_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load wholesale file exemptions from BOTH lists (this gate's own, plus the
# reused personal-token-denylist one — see header).
# ---------------------------------------------------------------------------
exempt_files=()
_load_exempt() {
  local file="$1" ex
  [[ -f "$file" ]] || return 0
  while IFS= read -r ex || [[ -n "$ex" ]]; do
    ex="${ex%%#*}"
    ex="${ex#"${ex%%[![:space:]]*}"}"
    ex="${ex%"${ex##*[![:space:]]}"}"
    [[ -z "$ex" ]] && continue
    exempt_files+=("$ex")
  done < "$file"
}
_load_exempt "$PRERENAME_EXEMPT_FILE"
_load_exempt "$KERNEL_DENYLIST_EXEMPT_FILE"

_prerename_is_exempt() {
  local target="$1" ex
  for ex in "${exempt_files[@]+"${exempt_files[@]}"}"; do
    [[ "$target" == "$ex" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Load the verdict table into parallel arrays (bash-3.2-safe, no assoc
# arrays — same linear-scan idiom as check-personal-token-denylist.sh).
# ---------------------------------------------------------------------------
v_kinds=()
v_tokens=()
v_verdicts=()
while IFS=$'\t' read -r kind token verdict _rationale || [[ -n "${kind:-}" ]]; do
  [[ -z "${kind:-}" ]] && continue
  case "$kind" in \#*) continue ;; esac
  case "$kind" in env | path-leaf) ;; *) continue ;; esac
  [[ -z "${token:-}" ]] && continue
  v_kinds+=("$kind")
  v_tokens+=("$token")
  v_verdicts+=("${verdict:-}")
done < "$PRERENAME_VERDICTS_FILE"

_prerename_lookup() {
  # _prerename_lookup <kind> <token> — echoes the verdict if found (rc 0),
  # else nothing (rc 1).
  local want_kind="$1" want_token="$2" i
  for i in "${!v_kinds[@]}"; do
    [[ "${v_kinds[$i]}" == "$want_kind" ]] || continue
    [[ "${v_tokens[$i]}" == "$want_token" ]] || continue
    printf '%s' "${v_verdicts[$i]}"
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Scan every kernel-set file for the four identifier shapes described above.
# One `grep -noE` per shape per file (not per line) — mirrors
# check-personal-token-denylist.sh's per-pattern-per-file idiom.
# ---------------------------------------------------------------------------
violations=0
files_checked=0
covered=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if _prerename_is_exempt "$f"; then
    continue
  fi
  files_checked=$((files_checked + 1))
  path="$KERNEL_MANIFEST_ROOT/$f"
  [[ -f "$path" ]] || continue

  # --- shape 1: FOUNDATION_<NAME> env-var identifiers -----------------------
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    lineno="${hit%%:*}"
    token="${hit#*:}"
    if _prerename_lookup env "$token" >/dev/null; then
      covered=$((covered + 1))
    else
      printf '%s:%s: [env] unreviewed FOUNDATION_-prefixed identifier: %s\n' "$f" "$lineno" "$token"
      violations=$((violations + 1))
    fi
  done < <(grep -noE 'FOUNDATION_[A-Z][A-Z0-9_]*' "$path" 2>/dev/null || true)

  # --- shape 2: .foundation/<leaf> (per-repo compat dir) — always allowed ---
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    covered=$((covered + 1))
  done < <(grep -noE '\.foundation/[A-Za-z0-9._-]*' "$path" 2>/dev/null || true)

  # --- shape 3: bin/foundation (CLI compat shim path) — always allowed ------
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    covered=$((covered + 1))
  done < <(grep -noE 'bin/foundation\b' "$path" 2>/dev/null || true)

  # --- shape 4: foundation/<leaf>, NOT dot-prefixed, XDG-anchored ----------
  # The leading `[^.]` requires (and consumes) one non-dot character
  # immediately before "foundation/", which is what keeps this shape from
  # re-matching a `.foundation/<leaf>` hit already counted under shape 2
  # (grep's per-match search never overlaps a previous match, but a SEPARATE
  # grep call over the same line has no such state, so the exclusion has to
  # be structural in the pattern itself). A candidate line must ALSO carry
  # an XDG-home-shaped anchor (see header) — this two-step (grep the whole
  # LINE first, then re-check + extract) is what excludes a `foundation/...`
  # prose reference to the separate, real, still-`foundation`-named overlay
  # repo, which shares none of these XDG-anchor spellings.
  while IFS= read -r line_rec; do
    [[ -z "$line_rec" ]] && continue
    lineno="${line_rec%%:*}"
    line_text="${line_rec#*:}"
    case "$line_text" in
      *XDG_*_HOME*|*'~/.config'*|*'~/.cache'*|*'~/.local/share'*|*'~/.local/state'*|*'~/.local/bin'*| \
      *"\$HOME/.config"*|*"\$HOME/.cache"*|*"\$HOME/.local/share"*|*"\$HOME/.local/state"*|*"\$HOME/.local/bin"*) ;;
      *) continue ;;
    esac
    match="$(printf '%s\n' "$line_text" | grep -oE '[^.]foundation/[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?' | head -n1)"
    [[ -z "$match" ]] && continue
    # Strip the one required non-dot lead-in char, then the "foundation/" prefix.
    leaf="${match:1}"
    leaf="${leaf#foundation/}"
    [[ -z "$leaf" ]] && continue
    if _prerename_lookup path-leaf "$leaf" >/dev/null; then
      covered=$((covered + 1))
    else
      printf '%s:%s: [path-leaf] unreviewed foundation/%s legacy subdir leaf\n' "$f" "$lineno" "$leaf"
      violations=$((violations + 1))
    fi
  done < <(grep -nE '[^.]foundation/[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?' "$path" 2>/dev/null || true)

done < <("$SCRIPT_DIR/list-kernel-set.sh" --root "$KERNEL_MANIFEST_ROOT")

if (( violations > 0 )); then
  echo "---"
  echo "FAIL: $violations unreviewed pre-rename identifier occurrence(s) across $files_checked kernel file(s) ($covered known-verdict occurrence(s) allowed)" >&2
  echo "Fix: rename to the TEMPERLOOP_* / temperloop/ equivalent, OR — if this is a" >&2
  echo "     genuinely new grandfathered path needing its own migrate-vs-allowlist" >&2
  echo "     verdict — add a reviewed row to $PRERENAME_VERDICTS_FILE." >&2
  exit 1
fi

echo "OK — 0 unreviewed pre-rename identifier occurrences across $files_checked kernel file(s) ($covered known-verdict occurrence(s) allowed per prerename-leak-verdicts.tsv)"
