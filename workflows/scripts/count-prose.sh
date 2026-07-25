#!/usr/bin/env bash
#
# count-prose.sh — kernel prose-plane baseline counter (temperloop#719, item
# prose-baseline-measurement / #722).
#
# Reports the two numbers the two-tier CI budget gate (docs/adr/
# 0015-prose-plane-budget-gate.md, item prose-budget-gate / #725) seeds its
# caps from:
#
#   TIER-1 — line count of the composed KERNEL-AUTHORED render only:
#            claude/CLAUDE.kernel.md rendered through the existing compose
#            seam (workflows/scripts/install-claude-md.sh's own
#            render_kernel_doc, invoked via its INSTALL_CLAUDE_MD_KERNEL_ONLY
#            render-only mode) — never a second, duplicated compose
#            implementation living in this script (ADR 0015). The
#            host-rendered "## Knowledge store routing" section and the
#            personal `claude/CLAUDE.overlay.md` are excluded — this is the
#            kernel-authored surface alone, never the kernel+overlay total.
#   TIER-2 — a line count for every tracked file matching `claude/**/*.md`
#            (agent charters under claude/agents/ included), plus the sum
#            across all of them.
#
# Usage:
#   workflows/scripts/count-prose.sh
#
# Stranger-clean: no vault/overlay/org dependency. This script and the seam
# it calls read only tracked repo files (claude/CLAUDE.kernel.md,
# workflows/scripts/install-claude-md.sh, workflows/scripts/build/
# build.config.sh) — it never reads claude/CLAUDE.overlay.md, the knowledge
# store, or the operator's friction ledger.
#
# Host determinism (verified in CI by workflows/scripts/tests/
# test_count_prose.sh, which runs on both the ubuntu-latest and
# macos-latest CI legs, matching whatever host authored the numbers):
#   - BUILD_CONFIG_MACHINE and BUILD_CONFIG_LOCAL are pinned to /dev/null
#     before invoking the compose seam. build.config.sh sources both paths
#     (precedence layers 3/4) only `if [ -f "$path" ]`; /dev/null is never a
#     regular file, so both sourcing blocks silently no-op regardless of
#     what a real host's XDG machine conf or a checkout's untracked
#     build.config.local.sh contain. This neutralizes the two config-FILE
#     layers (3/4) to the TRACKED repo defaults (layer 5) only.
#   - THIS PROCESS'S OWN ENVIRONMENT is also scrubbed of every
#     build.config.sh setting name before invoking the seam — layer 2 (an
#     exported env var) OUTRANKS layer 5's tracked `:=` default, so an
#     inherited `EPIC_MIN_SUBUNITS`/`DISPLAY_TZ` (e.g. from a pipeline-drive
#     session, or a caller's own shell) would otherwise flow straight
#     through the `:=` idiom and perturb the render even with layers 3/4
#     neutralized above. `build-config-settings.sh` is the SSOT-derived name
#     list (temperloop#1241 — the same mechanism build-level.mjs's 3e.5 gate
#     already uses to make `quality-gates.sh` hermetic under pipeline-drive);
#     unsetting every name it prints, rather than hand-listing
#     EPIC_MIN_SUBUNITS/DISPLAY_TZ ourselves, means a future setting addition
#     to build.config.sh is covered here with no edit to this script.
#   - Combined, the {{EPIC_MIN_SUBUNITS}} / {{DISPLAY_TZ}} setting substitution
#     baked into the kernel doc's rendered text is identical on every host
#     and every CI runner — no machine-specific override, checkout-local
#     override, OR inherited-env override can perturb the tier-1 number.
#   - Tracked-file enumeration goes through `git ls-files` (never a
#     filesystem glob), so an untracked scratch file dropped under claude/
#     on the authoring host can never inflate tier-2 relative to a clean CI
#     checkout.
#   - Line counts use `wc -l`, trimmed of the leading-whitespace padding
#     BSD `wc` prints (macOS) that GNU `wc` (Linux CI) does not, so the
#     printed number is identical text on both OS families, not just
#     numerically equal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${COUNT_PROSE_ROOT:=$REPO_ROOT}"  # setting:exempt — test/fixture root override (mirrors FEATURE_DOCS_ROOT/KERNEL_MANIFEST_ROOT), not an operator-facing config-precedence default
kernel_doc="$COUNT_PROSE_ROOT/claude/CLAUDE.kernel.md"
install_script="$COUNT_PROSE_ROOT/workflows/scripts/install-claude-md.sh"

[ -f "$kernel_doc" ] || { echo "count-prose: kernel doc not found: $kernel_doc" >&2; exit 1; }
[ -f "$install_script" ] || { echo "count-prose: compose seam not found: $install_script" >&2; exit 1; }
if [ ! -d "$COUNT_PROSE_ROOT/.git" ] && [ ! -f "$COUNT_PROSE_ROOT/.git" ]; then
  echo "count-prose: $COUNT_PROSE_ROOT is not a git checkout" >&2
  exit 1
fi

# lines_in <file> — echo a file's line count, trimmed. BSD `wc -l` (macOS)
# right-pads its count with leading spaces; GNU `wc -l` (Linux) does not —
# strip whitespace so the two OS families print byte-identical text, not
# just numerically equal counts.
lines_in() {
  wc -l <"$1" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# TIER-1 — the composed kernel-authored render, through the compose seam's
# own render-only mode (never a duplicated render here).
# ---------------------------------------------------------------------------
scratch="$(mktemp -d "${TMPDIR:-/tmp}/count-prose.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Scrub every build.config.sh setting NAME from this process's own environment
# before invoking the seam (see the header determinism note above — layer 2
# outranks the layer-3/4 file-pinning below, so an inherited exported setting
# must be unset here too). A missing/older helper prints nothing -> `unset`
# with no args is a harmless no-op.
settings_bin="$COUNT_PROSE_ROOT/workflows/scripts/build/build-config-settings.sh"
# shellcheck disable=SC2046  # intentional word-splitting: unset takes N bare NAME args, one per line from build-config-settings.sh
unset $(bash "$settings_bin" 2>/dev/null)

tier1_target="$scratch/kernel-only.md"
# The overlay path is never read or existence-checked when
# INSTALL_CLAUDE_MD_KERNEL_ONLY=1 (see install-claude-md.sh) — passed here
# only to satisfy the script's positional-arg contract.
BUILD_CONFIG_MACHINE=/dev/null \
BUILD_CONFIG_LOCAL=/dev/null \
INSTALL_CLAUDE_MD_KERNEL_ONLY=1 \
  "$install_script" "$kernel_doc" "$scratch/unused-overlay.md" "$tier1_target"

tier1_count="$(lines_in "$tier1_target")"

# ---------------------------------------------------------------------------
# TIER-2 — per-file line counts over every TRACKED claude/**/*.md file
# (git ls-files, never a filesystem glob — see the determinism note above).
# ---------------------------------------------------------------------------
cd "$COUNT_PROSE_ROOT" || exit 1

# Captured into a variable (never a `< <(process substitution)`) so a real
# failure anywhere in the pipeline is actually checked: a process
# substitution's own exit status is NOT observed by the `while read ... done
# < <(...)` construct that consumes it (a well-known bash gotcha — the loop
# only ever sees `read`'s own EOF-driven exit code), so a git/grep/sort
# failure there would silently degrade to an empty file list instead of a
# clear error. `set -o pipefail` (this file's own top-of-file `set -euo
# pipefail`) makes the command-substitution SUBSHELL's own exit code
# reflect the first failing pipeline stage; the explicit `||` below then
# actually observes that exit code, which the process-substitution form
# could not.
#   `grep`'s own "zero matches" exit (1) is deliberately absorbed (`|| true`)
#   so it never trips `pipefail` on its own — a real repo variant with zero
#   claude/**/*.md files is a legitimate, distinctly-messaged case (the
#   explicit `${#tier2_files[@]} -eq 0` check below), not a pipeline error.
#   A genuine `git ls-files` failure still trips pipefail via ITS stage.
if ! tier2_raw="$(git ls-files -- claude | { grep '\.md$' || true; } | LC_ALL=C sort)"; then
  echo "count-prose: failed to enumerate tracked claude/**/*.md files (git ls-files | grep | sort)" >&2
  exit 1
fi

tier2_files=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  tier2_files+=("$f")
done <<<"$tier2_raw"

if [ "${#tier2_files[@]}" -eq 0 ]; then
  echo "count-prose: zero tracked claude/**/*.md files found under $COUNT_PROSE_ROOT — nothing to count" >&2
  exit 1
fi

tier2_total=0
declare -a tier2_counts=()
for f in "${tier2_files[@]}"; do
  c="$(lines_in "$f")"
  tier2_counts+=("$c")
  tier2_total=$((tier2_total + c))
done

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
echo "TIER-1 kernel-authored composed render: ${tier1_count} lines"
echo "  (claude/CLAUDE.kernel.md rendered via workflows/scripts/install-claude-md.sh"
echo "   INSTALL_CLAUDE_MD_KERNEL_ONLY=1 — knowledge-store-routing + overlay excluded)"
echo
echo "TIER-2 per-file line counts (claude/**/*.md, agent charters included):"
i=0
for f in "${tier2_files[@]}"; do
  printf '%8d  %s\n' "${tier2_counts[$i]}" "$f"
  i=$((i + 1))
done
echo
echo "TIER-2 total: ${tier2_total} lines across ${#tier2_files[@]} files"
