#!/usr/bin/env bash
#
# validate-prose-budget.sh — two-tier CI prose-budget gate (temperloop#719,
# item prose-budget-gate / #725; ADR 0015).
#
# TIER-1: fails when the composed KERNEL-AUTHORED render (claude/
#         CLAUDE.kernel.md rendered through install-claude-md.sh's
#         INSTALL_CLAUDE_MD_KERNEL_ONLY seam — never the kernel+overlay
#         total) exceeds PROSE_BUDGET_TIER1_CAP lines.
# TIER-2: fails when ANY tracked claude/**/*.md file (agent charters
#         included) exceeds PROSE_BUDGET_TIER2_FILE_CAP lines — ONE uniform
#         per-file cap, never a per-file table (a per-file value would just
#         be a relocated exemption mechanism; this gate has none).
#
# Both counts come from workflows/scripts/count-prose.sh's own stdout report
# — this script re-implements NEITHER the compose-seam invocation nor the
# per-file `wc` walk (ADR 0015, "one compose seam"). It only PARSES that
# report and compares the two numbers it already carries against the two cap
# knobs. This is also why this gate is exactly as host-deterministic as
# count-prose.sh itself (see that script's own header) — nothing here adds a
# second, independently-driftable counting path.
#
# Ratchet: PROSE_BUDGET_TIER1_CAP / PROSE_BUDGET_TIER2_FILE_CAP (defaulted in
# workflows/scripts/build/build.config.sh, registered in
# workflows/scripts/config/knob-registry.tsv) are seeded at the measured
# baseline, so this gate is green on the unmodified tree by construction and
# blocks no unrelated PR. A cap is lowered again only by a later config PR
# (after a subtraction pass actually shrinks the prose) or raised by a config
# PR when new prose is deliberately added — never dodged by editing THIS
# script.
#
# Failure message contract (epic #719 Contract, Produces #4): every
# violation names the FILE, its COUNT, its CAP, and both remediation paths
# (trim the prose, or open a config PR raising the cap — build.config.sh's
# knob default AND its knob-registry.tsv row, in the SAME PR, per
# check-knob-registry.sh's equality lint). A TIER-1 failure additionally
# prints the full TIER-2 per-file breakdown alongside the composed total, so
# a seam-only regression (composed count grows, every per-file count stays
# flat) is attributable on sight, with no second investigation step.
#
# Scope: this item owns the SIZE-CAP checks only. A citation-marker-presence
# check is a separate, later item (citation-markers) — not implemented or
# stubbed here.
#
# Usage:
#   workflows/scripts/validate-prose-budget.sh
#
# Env overrides (fixture-driven tests):
#   COUNT_PROSE_ROOT       forwarded verbatim to count-prose.sh (its own
#                          test/fixture root override — see that script's
#                          header). A fixture pointing this at a scratch git
#                          checkout with a MODIFIED install-claude-md.sh (a
#                          compose-seam change) but byte-identical
#                          claude/**/*.md files demonstrates the tier-1-only
#                          breach case: composed count grows, every per-file
#                          count stays exactly the baseline value.
#   COUNT_PROSE_BIN        path to the count-prose.sh script itself (default:
#                          the sibling count-prose.sh next to this script).
#                          knob:exempt — test-double seam, not an
#                          operator-facing config-precedence default (mirrors
#                          count-prose.sh's own COUNT_PROSE_ROOT rationale).
#   PROSE_BUDGET_TIER1_CAP, PROSE_BUDGET_TIER2_FILE_CAP   override the
#                          build.config.sh knob defaults directly — the
#                          fixture red/green demonstrations use this to
#                          exercise a deliberate overage without editing
#                          build.config.sh (rung 2, env, always outranks
#                          rung 5's tracked default per the six-rung ladder).
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching every other
# workflows/scripts/*.sh checker in this family.

set -uo pipefail

# This script lives at workflows/scripts/validate-prose-budget.sh — the
# same directory as count-prose.sh — so REPO_ROOT is TWO levels up from
# SCRIPT_DIR, matching that script's own resolution exactly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${COUNT_PROSE_ROOT:=$REPO_ROOT}"
: "${COUNT_PROSE_BIN:=$SCRIPT_DIR/count-prose.sh}"  # knob:exempt — test-double seam (fixture: a modified compose seam under a scratch COUNT_PROSE_ROOT tree)

[ -f "$COUNT_PROSE_BIN" ] || { echo "validate-prose-budget: counting script not found: $COUNT_PROSE_BIN" >&2; exit 1; }

# Cap knobs: sourced from build.config.sh (tracked-repo rung 5) unless a
# caller already exported them (rung 2 — an env override — wins per the
# normal six-rung precedence ladder; this is exactly the seam the fixture
# red/green demonstrations below use).
if [ -f "$REPO_ROOT/workflows/scripts/build/build.config.sh" ]; then
  # shellcheck source=workflows/scripts/build/build.config.sh
  source "$REPO_ROOT/workflows/scripts/build/build.config.sh"
fi
: "${PROSE_BUDGET_TIER1_CAP:?PROSE_BUDGET_TIER1_CAP is unset — build.config.sh missing, or the knob was removed}"
: "${PROSE_BUDGET_TIER2_FILE_CAP:?PROSE_BUDGET_TIER2_FILE_CAP is unset — build.config.sh missing, or the knob was removed}"
case "$PROSE_BUDGET_TIER1_CAP" in ''|*[!0-9]*) echo "validate-prose-budget: PROSE_BUDGET_TIER1_CAP is not a positive integer: '$PROSE_BUDGET_TIER1_CAP'" >&2; exit 1 ;; esac
case "$PROSE_BUDGET_TIER2_FILE_CAP" in ''|*[!0-9]*) echo "validate-prose-budget: PROSE_BUDGET_TIER2_FILE_CAP is not a positive integer: '$PROSE_BUDGET_TIER2_FILE_CAP'" >&2; exit 1 ;; esac

# ---------------------------------------------------------------------------
# Run count-prose.sh and parse its report. Never re-derive either number.
# ---------------------------------------------------------------------------
report="$(COUNT_PROSE_ROOT="$COUNT_PROSE_ROOT" bash "$COUNT_PROSE_BIN" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "validate-prose-budget: count-prose.sh failed (exit $rc) — cannot evaluate the budget:" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# tier-1: first line reads "TIER-1 kernel-authored composed render: NNN
# lines" — anchored past "render: " and before " lines" (NOT a bare
# digit-run search, which would match the literal "1" in "TIER-1" itself
# before ever reaching the real count — see test_count_prose.sh's own
# extract_tier1 for the same fix, applied here identically).
tier1_count="$(printf '%s\n' "$report" | sed -n '1p' | sed -E 's/^.*render: ([0-9]+) lines.*$/\1/')"
case "$tier1_count" in
  ''|*[!0-9]*)
    echo "validate-prose-budget: could not parse a TIER-1 line count from count-prose.sh's report — parser drift against that script's output format?" >&2
    printf '%s\n' "$report" >&2
    exit 1
    ;;
esac

# tier-2: the per-file table between the "TIER-2 per-file line counts"
# header and the blank line before "TIER-2 total: ...". Each row is
# `printf '%8d  %s\n'` in count-prose.sh — right-justified count, two
# spaces, path.
tier2_files=()
tier2_counts=()
in_table=0
while IFS= read -r line; do
  case "$line" in
    "TIER-2 per-file line counts"*)
      in_table=1
      continue
      ;;
  esac
  if [ "$in_table" -eq 1 ]; then
    if [ -z "$line" ]; then
      in_table=0
      continue
    fi
    cnt="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+.*$/\1/')"
    fpath="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
    case "$cnt" in
      ''|*[!0-9]*) continue ;;  # not a data row (shouldn't happen; defensive)
    esac
    tier2_files+=("$fpath")
    tier2_counts+=("$cnt")
  fi
done <<REPORT_EOF
$report
REPORT_EOF

if [ "${#tier2_files[@]}" -eq 0 ]; then
  echo "validate-prose-budget: parsed zero TIER-2 files from count-prose.sh's report — parser drift against that script's output format?" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Evaluate both tiers. Collect ALL violations before failing (same
# collect-then-exit-nonzero shape as scripts/quality-gates.sh itself), so one
# run surfaces every offending file instead of one per re-run.
# ---------------------------------------------------------------------------
fail=0
violations=0
tier2_max=0

i=0
while [ "$i" -lt "${#tier2_files[@]}" ]; do
  f="${tier2_files[$i]}"
  c="${tier2_counts[$i]}"
  if [ "$c" -gt "$tier2_max" ]; then
    tier2_max="$c"
  fi
  if [ "$c" -gt "$PROSE_BUDGET_TIER2_FILE_CAP" ]; then
    fail=1
    violations=$((violations + 1))
    echo "PROSE-BUDGET TIER-2: $f: $c lines exceeds the per-file cap of $PROSE_BUDGET_TIER2_FILE_CAP lines (PROSE_BUDGET_TIER2_FILE_CAP)"
    echo "  Remediation: trim $f back under the cap, OR open a config PR raising PROSE_BUDGET_TIER2_FILE_CAP in workflows/scripts/build/build.config.sh (+ its workflows/scripts/config/knob-registry.tsv row, in the SAME PR)"
  fi
  i=$((i + 1))
done

if [ "$tier1_count" -gt "$PROSE_BUDGET_TIER1_CAP" ]; then
  fail=1
  violations=$((violations + 1))
  [ "$violations" -gt 1 ] && echo
  echo "PROSE-BUDGET TIER-1: composed kernel-authored render is $tier1_count lines, exceeding the cap of $PROSE_BUDGET_TIER1_CAP lines (PROSE_BUDGET_TIER1_CAP)"
  echo "  Remediation: trim claude/CLAUDE.kernel.md (or whatever compose-seam change inflated the render) back under the cap, OR open a config PR raising PROSE_BUDGET_TIER1_CAP in workflows/scripts/build/build.config.sh (+ its workflows/scripts/config/knob-registry.tsv row, in the SAME PR)"
  echo
  echo "  Full TIER-2 per-file breakdown, for seam-attribution — every count here matching a prior green run means this IS a compose-seam-only regression (zero per-file prose change), not a per-file overage:"
  printf '%s\n' "$report" | sed -n '/^TIER-2 per-file line counts/,$p' | sed 's/^/  /'
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: $violations prose-budget violation(s)" >&2
  exit 1
fi
echo "OK — prose budget clean: tier-1 $tier1_count/$PROSE_BUDGET_TIER1_CAP lines; tier-2 ${#tier2_files[@]} file(s) checked against a $PROSE_BUDGET_TIER2_FILE_CAP-line uniform cap (largest: $tier2_max lines)"
