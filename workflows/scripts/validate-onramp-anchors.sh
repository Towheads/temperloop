#!/usr/bin/env bash
#
# validate-onramp-anchors.sh — assert every registered on-ramp anchor still
# names its canonical value, and none names a retired one.
#
# Per ADR 0024 ("cross-surface coherence is asserted positively", docs/adr/
# 0024-cross-surface-coherence-is-asserted-positively.md, temperloop#1117):
# the command a newcomer should run first is named in four places with no
# structural relationship to each other (bin/temperloop's first-run banner,
# README.md's quickstart, bin/README.md, docs/features/install-cli.md), and
# they drifted silently once already (temperloop#1116). The fix is NOT a
# tree-wide grep for the retired name — that gate ships with an exemption
# list on day one (CHANGELOG.md, docs/adr/**, Plans-archive/** name the
# retired command legitimately, as history) and the exemption list becomes
# the thing people edit to make the build green. This script is the
# validate-capture-backstop.sh / validate-activation-registry.sh MOLD
# applied instead: a registered anchor set (workflows/scripts/config/
# onramp-anchors.tsv), a POSITIVE assertion per anchor (it names its
# canonical value), and a NEGATIVE assertion scoped to that same anchor set
# only (it names no retired value) — never a whole-tree sweep.
#
# ── Per-row check ────────────────────────────────────────────────────────
# Each registry row is <anchor-path> <locator-line> <value-key>. For each
# row, this script reads a WINDOW of lines around the locator (not the exact
# line only, and never the whole file) and:
#   POSITIVE — the window, with the Unicode arrow `→` normalized to the
#     ASCII `->` (see § Arrow-glyph normalization below), contains the
#     value-key's canonical string as a literal substring.
#   NEGATIVE — the SAME window contains no retired token (`try`, `sandbox`),
#     whole-word matched so "entry"/"industry"/"sandboxed-elsewhere" style
#     false positives don't fire.
# A locator that has drifted out of its window is real registry-maintenance
# signal (the row needs updating), not gate fragility to route around — see
# the registry's own header.
#
# ── Arrow-glyph normalization ────────────────────────────────────────────
# README.md and bin/README.md write the adoption-path phrase with the
# Unicode arrow (`→`); docs/features/install-cli.md writes the same phrase
# with the ASCII arrow (`->`) — both legitimate prose, same meaning. A
# single canonical string would be FALSE on day one against whichever
# variant it didn't pick, and a substring loose enough to match both would
# assert nothing (ADR 0024's own acceptance warning). So: normalize the
# anchor's own text (Unicode arrow -> ASCII arrow) before comparing, via
# plain bash parameter substitution (`${window//→/->}`) — this works
# byte-for-byte regardless of locale (verified under both the default UTF-8
# shell locale and LC_ALL=C), unlike `sed 's/→/.../'`, whose behavior can
# vary with the runner's locale. The canonical value itself is therefore
# always the ASCII form; see canonical_value() below.
#
# ── Canonical-value table ────────────────────────────────────────────────
# Deliberately a small, in-script table (not a second registry file) — the
# same "one small lookup, not duplicated per row" shape the registry's own
# header describes. Value keys, at minimum:
#   installer-command  the `curl -fsSL .../bin/bootstrap.sh` install line
#   first-subcommand   the subcommand a newcomer runs after install
#   onramp-noun        the bare onramp noun itself ("testbed") — this is
#                       what makes the sandbox -> testbed rename gated by
#                       this script rather than left to prose review
#   adoption-path       the full "testbed -> first epic -> promote -> adopt"
#                       phrase (ASCII-normalized, see above)
#
# ── Known, accepted weakness (ADR 0024 § Consequences) ──────────────────────
# A surface that SHOULD be an anchor but was never registered is silently
# unchecked, and nothing announces that. Accepted deliberately: the
# alternative (a tree-wide sweep) fails worse — see the registry header and
# ADR 0024 itself.
#
# Usage: workflows/scripts/validate-onramp-anchors.sh
# Override ONRAMP_GATE_ROOT to point at a different tree (used by this
# script's own fixture test, workflows/scripts/tests/test_validate_onramp_
# anchors.sh) — same override-env-var shape as check-changelog-entry.sh's
# CHANGELOG_GATE_ROOT.
#
# Kept POSIX-bash-3.2 friendly (no mapfile, no associative arrays) so it runs
# on the macOS dev shell as well as Linux CI.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
: "${ONRAMP_GATE_ROOT:=$REPO_ROOT_DEFAULT}"
REPO="$ONRAMP_GATE_ROOT"

# ── Self-scoping (temperloop#1490) ─────────────────────────────────────────
# ADR 0024's four registered anchors are KERNEL-PRODUCT onramp prose — the
# CLI's own first-run banner, this repo's README quickstart, bin/README.md,
# docs/features/install-cli.md's adoption-path paragraph, all narrating
# `temperloop testbed -> first epic -> promote -> adopt`. A repo that
# vendors this kernel as a subtree (foundation, stageFind, ssmobile,
# subsetwiki) is not itself an adopter-facing kernel product and has no
# obligation for its OWN root README/bin/docs to carry that narrative — yet
# $REPO above resolves to that consumer's root whenever this script is
# reached through its compat symlink (e.g. foundation's workflows/scripts/
# validate-onramp-anchors.sh -> ../../kernel/workflows/scripts/validate-
# onramp-anchors.sh), so without this check every registered anchor would
# fail there for a reason that has nothing to do with drift.
#
# Detection mirrors workflows/scripts/tests/lib/sandbox.sh's
# sandbox_skip_if_composed_tree (temperloop#267/#488) — same two signals,
# reimplemented inline rather than sourced: this is a production KERNEL_GATES
# validator (a `bash workflows/scripts/validate-onramp-anchors.sh` gate
# entry, and its own `make validate-onramp-anchors` target for a human to run
# locally), never a test, and test infra (workflows/scripts/tests/lib/)
# stays test-scoped rather than becoming a dependency of shipped gate
# machinery.
#
# Deliberately keyed on $REPO (which honors an ONRAMP_GATE_ROOT override),
# not on some separate "am I in an overlay" global — so the fixture suite
# below, which always points ONRAMP_GATE_ROOT at a throwaway mktemp tree,
# never trips this (a throwaway fixture dir carries neither signal).
if { [ -f "$REPO/claude/CLAUDE.kernel.md" ] && [ -f "$REPO/claude/CLAUDE.overlay.md" ]; } \
   || { [ -d "$REPO/kernel" ] && { [ -f "$REPO/kernel/bin/temperloop" ] || [ -f "$REPO/kernel/claude/CLAUDE.kernel.md" ]; }; }; then
  echo "SKIP: validate-onramp-anchors — composed overlay tree detected at $REPO."
  if [ -f "$REPO/claude/CLAUDE.kernel.md" ] && [ -f "$REPO/claude/CLAUDE.overlay.md" ]; then
    echo "  claude/CLAUDE.overlay.md is present beside claude/CLAUDE.kernel.md under $REPO/claude."
  else
    echo "  a kernel/ subtree is vendored at the repo root ($REPO/kernel)."
  fi
  echo "  ADR 0024's four onramp anchors (bin/temperloop's first-run banner,"
  echo "  README.md's quickstart, bin/README.md, docs/features/install-cli.md)"
  echo "  are kernel-PRODUCT onramp prose (temperloop#1117) — a vendoring"
  echo "  consumer repo is not itself an adopter-facing kernel product and"
  echo "  carries no obligation for its own root surfaces to narrate it."
  echo "  Exiting 0 (legible skip, not a failure)."
  exit 0
fi

REGISTRY="$REPO/workflows/scripts/config/onramp-anchors.tsv"

# Lines of context on each side of a registered locator. Generous enough to
# absorb an unrelated edit elsewhere in the file, small enough to stay
# "scoped to the anchor", never "scoped to the whole file" (see registry
# header § Locator drift).
WINDOW=8

# canonical_value <key> — echoes the ONE canonical string for a value-key, or
# returns 1 (echoing nothing) for an unrecognized key, which the caller
# reports as a hard failure (an unknown key in the registry is a typo, never
# a silent skip).
canonical_value() {
  case "$1" in
    installer-command)
      printf '%s' 'curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh' ;;
    first-subcommand)
      printf '%s' 'temperloop testbed' ;;
    onramp-noun)
      printf '%s' 'testbed' ;;
    adoption-path)
      printf '%s' 'testbed -> first epic -> promote -> adopt' ;;
    *)
      return 1 ;;
  esac
}

# Retired values a registered anchor must never name, whole-word matched
# (grep -w) so "entry"/"industry"/"country" don't false-positive on "try".
# Scoped ONLY to the windows the registry names — never the rest of the
# file, never the rest of the tree (ADR 0024's own scoping rule).
RETIRED_TOKENS='try
sandbox'

if [ ! -f "$REGISTRY" ]; then
  echo "validate-onramp-anchors: FAIL — registry not found: $REGISTRY"
  exit 1
fi

fail=0
nchecked=0

while IFS=$'\t' read -r anchor_path locator key || [ -n "$anchor_path" ]; do
  case "$anchor_path" in
    ''|'#'*) continue ;;
  esac

  label="$anchor_path:$locator"

  if [ -z "$locator" ] || [ -z "$key" ]; then
    echo "FAIL  $anchor_path (malformed row — expected 3 tab-separated columns)"
    fail=$((fail + 1))
    continue
  fi
  case "$locator" in
    ''|*[!0-9]*)
      echo "FAIL  $label (malformed row — locator is not a line number: '$locator')"
      fail=$((fail + 1))
      continue ;;
  esac

  file="$REPO/$anchor_path"
  if [ ! -f "$file" ]; then
    echo "FAIL  $label ($key) — anchor file missing: $anchor_path"
    fail=$((fail + 1))
    continue
  fi

  expected="$(canonical_value "$key" || true)"
  if [ -z "$expected" ]; then
    echo "FAIL  $label — unknown value-key '$key' (not in canonical_value()'s table)"
    fail=$((fail + 1))
    continue
  fi

  nchecked=$((nchecked + 1))

  total_lines="$(wc -l < "$file" | tr -d ' ')"
  lo=$((locator - WINDOW))
  [ "$lo" -lt 1 ] && lo=1
  hi=$((locator + WINDOW))
  [ "$hi" -gt "$total_lines" ] && hi="$total_lines"

  window="$(sed -n "${lo},${hi}p" "$file")"
  # Arrow-glyph normalization — see header § Arrow-glyph normalization.
  normalized="${window//→/->}"

  # (No `grep -q` on the read end of a pipe here — see
  # scripts/lint-pipe-grep-q.sh's own header: `-q` exits on first match
  # without draining stdin, which SIGPIPEs the writer under `pipefail`,
  # nondeterministically. `-q` dropped, stdout redirected to /dev/null
  # instead — same exit-status contract, no race.)
  pos_ok=1
  printf '%s\n' "$normalized" | grep -F -- "$expected" >/dev/null || pos_ok=0

  neg_hit=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if printf '%s\n' "$window" | grep -wE -- "$tok" >/dev/null; then
      neg_hit="$tok"
      break
    fi
  done <<EOF
$RETIRED_TOKENS
EOF

  if [ "$pos_ok" = "1" ] && [ -z "$neg_hit" ]; then
    echo "ok    $label ($key)"
  elif [ -n "$neg_hit" ]; then
    echo "FAIL  $label ($key) — retired value '$neg_hit' found in lines $lo-$hi"
    fail=$((fail + 1))
  else
    echo "FAIL  $label ($key) — expected value not found in lines $lo-$hi: \"$expected\""
    fail=$((fail + 1))
  fi
done < "$REGISTRY"

echo "---"
echo "checked: $nchecked | failures: $fail"
if [ "$fail" -ne 0 ]; then
  echo "validate-onramp-anchors: FAIL"
  exit 1
fi
echo "validate-onramp-anchors: OK"
