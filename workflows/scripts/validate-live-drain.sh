#!/usr/bin/env bash
#
# validate-live-drain.sh — assert every Live/Drain pairing is whole.
#
# The live/drain pairing registry (see Patterns/Live-Drain pairing) is a set of
# (live rule, drain backstop) pairs: each real-time extraction rule in a
# CLAUDE.md is paired with a backstop step in /drain-mind, so a missed live
# capture is caught at drain time. The registry is split across TWO tables
# (foundation F#809, epic B "kernel routing"):
#   - the "## Live/Drain pairings" table at the top of
#     claude/commands/drain-mind.md is the SINGLE SOURCE OF TRUTH for KERNEL
#     pairs — rules generic enough that a stranger's kernel-only checkout
#     needs them backstopped too;
#   - claude/live-drain-registry.overlay.md (an overlay-only file, present
#     only in a composed/overlay checkout) carries a second
#     "## Live/Drain pairings — overlay extension" table for pairs that
#     reference Travis-personal (vault-backed) rules and have no meaning in
#     a standalone kernel checkout.
# This script parses the kernel table always, and UNIONS in the overlay
# extension table when that file is present — so a standalone kernel
# checkout validates the kernel table alone (self-contained, zero overlay
# references needed to pass), while a composed checkout validates the full
# union. Either way it FAILS (exit 1) if any pair, in either table, is
# HALF-PRESENT — a live anchor present without its drain anchor, or vice
# versa — which is the silent-loss failure mode the pairing pattern exists
# to prevent.
#
# Verifiability of the live half varies by source:
#   - foundation-local files (claude/CLAUDE.md, the repo root CLAUDE.md) are
#     hard-checked. `claude/CLAUDE.md` itself no longer exists as a single
#     tracked file (foundation Epic B "layered CLAUDE.md"): it is now
#     COMPOSED at install time from claude/CLAUDE.kernel.md +
#     claude/CLAUDE.overlay.md (workflows/scripts/install-claude-md.sh). A
#     live anchor can land in either source file, so this script checks a
#     throwaway concatenation of both — the composed real file under
#     ~/.claude isn't something CI can rely on (machine-specific, generated),
#     but the two tracked sources are always present in the checkout;
#   - `system-prompt` is not a file (the auto-memory rule lives in the harness
#     system prompt) — unverifiable, so ONLY the drain half is checked;
#   - stageFind/CLAUDE.md lives in another repo — checked when that checkout is
#     present (STAGEFIND_DIR, default ../stageFind), soft-skipped with a warning
#     otherwise so foundation CI needs no stageFind checkout.
# The drain half is always in drain-mind.md and is always hard-checked.
#
# Usage: workflows/scripts/validate-live-drain.sh   (resolves the repo itself)
# Kept POSIX-bash-3.2 friendly (no mapfile/associative arrays) so it runs on the
# macOS dev shell as well as Linux CI.

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRAIN="$REPO/claude/commands/drain-mind.md"
DRAIN_OVERLAY_EXT="$REPO/claude/live-drain-registry.overlay.md"
STAGEFIND_DIR="${STAGEFIND_DIR:-$REPO/../stageFind}"
CLAUDE_MD_KERNEL="$REPO/claude/CLAUDE.kernel.md"
CLAUDE_MD_OVERLAY="$REPO/claude/CLAUDE.overlay.md"
CLAUDE_MD_COMBINED=""
# Kernel-only checkout (foundation #803's seeded kernel repo: kernel half
# present, overlay half never shipped there — not the pre-split legacy case,
# which has neither). In this mode a live anchor absent from the kernel half
# alone is UNVERIFIABLE, not a drift signal: it may legitimately live only in
# the overlay half this checkout doesn't carry. See the live/drain loop below.
KERNEL_ONLY_MD=0
if [ -f "$CLAUDE_MD_KERNEL" ] && [ ! -f "$CLAUDE_MD_OVERLAY" ]; then
  KERNEL_ONLY_MD=1
fi

fail=0
warn=0
npairs=0

cleanup() { [ -n "$CLAUDE_MD_COMBINED" ] && rm -f "$CLAUDE_MD_COMBINED"; return 0; }
trap cleanup EXIT

# Map a Live-location <source> token to a filesystem path, or "SKIP:<reason>"
# for an unverifiable or absent source.
resolve_source() {
  case "$1" in
    system-prompt)        printf 'SKIP:live half is the harness system prompt (unverifiable)' ;;
    claude/CLAUDE.md)
      if [ -f "$CLAUDE_MD_KERNEL" ] && [ -f "$CLAUDE_MD_OVERLAY" ]; then
        # A live anchor can land in either split source — check a throwaway
        # concatenation of both (built once, reused across pairs).
        if [ -z "$CLAUDE_MD_COMBINED" ]; then
          CLAUDE_MD_COMBINED="$(mktemp "${TMPDIR:-/tmp}/validate-live-drain-claude-md.XXXXXX")"
          cat "$CLAUDE_MD_KERNEL" "$CLAUDE_MD_OVERLAY" >"$CLAUDE_MD_COMBINED"
        fi
        printf '%s' "$CLAUDE_MD_COMBINED"
      elif [ "$KERNEL_ONLY_MD" = "1" ]; then
        # Kernel-only checkout: check the kernel half alone. The caller
        # downgrades an absent-anchor result to a skip for this case (see the
        # live/drain loop) rather than treating it as a hard fail.
        printf '%s' "$CLAUDE_MD_KERNEL"
      else
        # Legacy single-file fallback (pre-split checkout).
        printf '%s' "$REPO/claude/CLAUDE.md"
      fi ;;
    foundation/CLAUDE.md) printf '%s' "$REPO/CLAUDE.md" ;;
    stageFind/CLAUDE.md)
      if [ -f "$STAGEFIND_DIR/CLAUDE.md" ]; then
        printf '%s' "$STAGEFIND_DIR/CLAUDE.md"
      else
        printf 'SKIP:stageFind not checked out at %s' "$STAGEFIND_DIR"
      fi ;;
    *)                    printf 'SKIP:unknown source %s' "$1" ;;
  esac
}

# anchor_present <file> <anchor> -> 0 if the anchor appears in the file as a
# markdown heading ("## Anchor") or a bold label ("**Anchor").
anchor_present() {
  local file="$1" anchor="$2"
  [ -f "$file" ] || return 1
  if grep -Eq "^#{1,6}[[:space:]]+${anchor}([[:space:](.]|\$)" "$file"; then return 0; fi
  if grep -Fq "**${anchor}" "$file"; then return 0; fi
  return 1
}

# tokens <string> -> backticked tokens, one per line, backticks stripped.
tokens() {
  # SC2016: the backticks in the regex are literal (match `...` spans), not a
  # command substitution — single quotes are intentional.
  # shellcheck disable=SC2016
  printf '%s' "$1" | grep -oE '`[^`]+`' | tr -d '`' || true
}

# check_anchors <file> <newline-list> -> "present" or "absent:<first-missing>"
check_anchors() {
  local file="$1" list="$2" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if ! anchor_present "$file" "$a"; then
      printf 'absent:%s' "$a"
      return 0
    fi
  done <<EOF
$list
EOF
  printf 'present'
}

# Extract the pairing-table data rows from <file> (drop the header +
# separator rows). Matches any heading starting "## Live/Drain pairings" —
# so it works unchanged on both the kernel table's plain heading and the
# overlay extension's "## Live/Drain pairings — overlay extension" heading.
extract_pairing_rows() {
  awk '
    /^## Live\/Drain pairings/ { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec && /^\|/ { print }
  ' "$1" | grep -vE '^\|[[:space:]]*Live rule|^\|[[:space:]]*-' || true
}

kernel_rows="$(extract_pairing_rows "$DRAIN")"
if [ -z "$kernel_rows" ]; then
  echo "FAIL: no '## Live/Drain pairings' table found in $DRAIN"
  exit 1
fi

# Union in the overlay extension table, only when present (a composed
# checkout). A standalone kernel checkout (temperloop, or this
# script's own scratch-clone simulation of it) has no
# claude/live-drain-registry.overlay.md and validates the kernel table alone.
composed=0
overlay_ext_rows=""
if [ -f "$DRAIN_OVERLAY_EXT" ]; then
  composed=1
  overlay_ext_rows="$(extract_pairing_rows "$DRAIN_OVERLAY_EXT")"
  if [ -z "$overlay_ext_rows" ]; then
    echo "FAIL: $DRAIN_OVERLAY_EXT present but has no '## Live/Drain pairings' table"
    exit 1
  fi
fi

rows="$kernel_rows"
if [ -n "$overlay_ext_rows" ]; then
  rows="$(printf '%s\n%s\n' "$kernel_rows" "$overlay_ext_rows")"
fi

if [ "$composed" = "1" ]; then
  echo "layout: composed (kernel table + overlay extension: $DRAIN_OVERLAY_EXT)"
else
  echo "layout: standalone kernel (no overlay extension present)"
fi

while IFS= read -r row; do
  [ -n "$row" ] || continue
  npairs=$((npairs + 1))

  name="$(printf '%s' "$row" | awk -F'|' '{print $2}' | sed 's/^ *//; s/ *$//')"
  live_cell="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
  drain_cell="$(printf '%s' "$row" | awk -F'|' '{print $4}')"

  # --- live half ---
  live_toks="$(tokens "$live_cell")"
  src="$(printf '%s\n' "$live_toks" | sed -n '1p')"
  live_anchors="$(printf '%s\n' "$live_toks" | sed -n '2,$p')"
  live_note=""
  if [ -z "$src" ]; then
    live_state="present"
  else
    path="$(resolve_source "$src")"
    case "$path" in
      SKIP:*) live_state="skip"; live_note="${path#SKIP:}" ;;
      *)
        live_state="$(check_anchors "$path" "$live_anchors")"
        # Kernel-only checkout: an anchor absent from the kernel half alone
        # may legitimately live only in the (unshipped) overlay half — not
        # verifiable either way here, so don't hard-fail it.
        if [ "$KERNEL_ONLY_MD" = "1" ] && [ "$src" = "claude/CLAUDE.md" ]; then
          case "$live_state" in
            absent:*)
              live_state="skip"
              live_note="live half unverifiable in a kernel-only checkout (no claude/CLAUDE.overlay.md); anchor not found in claude/CLAUDE.kernel.md alone, may live in the overlay half"
              ;;
          esac
        fi
        ;;
    esac
  fi

  # --- drain half ---
  drain_state="$(check_anchors "$DRAIN" "$(tokens "$drain_cell")")"

  # --- verdict ---
  case "$live_state:$drain_state" in
    present:present)
      echo "ok    $name" ;;
    skip:present)
      echo "skip  $name (live half unverifiable: $live_note — drain half present)"
      warn=$((warn + 1)) ;;
    present:absent:*)
      echo "FAIL  $name (HALF-PRESENT: live present, drain anchor missing: ${drain_state#absent:})"
      fail=$((fail + 1)) ;;
    absent:*:present)
      echo "FAIL  $name (HALF-PRESENT: drain present, live anchor missing: ${live_state#absent:})"
      fail=$((fail + 1)) ;;
    skip:absent:*)
      echo "FAIL  $name (drain anchor missing: ${drain_state#absent:}; live half unverifiable)"
      fail=$((fail + 1)) ;;
    *)
      echo "FAIL  $name (live=$live_state drain=$drain_state)"
      fail=$((fail + 1)) ;;
  esac
done <<EOF
$rows
EOF

echo "---"
echo "pairs: $npairs | failures: $fail | warnings: $warn"
if [ "$fail" -ne 0 ]; then
  echo "validate-live-drain: FAIL"
  exit 1
fi
echo "validate-live-drain: OK"
