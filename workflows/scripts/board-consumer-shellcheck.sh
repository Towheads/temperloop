#!/usr/bin/env bash
#
# board-consumer-shellcheck.sh — lint the SYNCED board file set the way a
# vendored consumer actually does, so a finding that would red every
# consumer's `checks` job fails at the SOURCE instead (temperloop#915,
# follow-up to the SYSTEMIC half of temperloop#905, which fixed one file and
# left the class open).
#
# THE GAP: `make shellcheck` (scripts/quality-gates.sh's own kernel-wide
# lint) runs
#
#   find . -name '*.sh' ... -not -path '*/tests/*' | xargs shellcheck -e SC1091
#
# i.e. it EXCLUDES every tests/ directory and SUPPRESSES SC1091 ("source file
# not found") repo-wide. stageFind/ssmobile/subsetwiki instead vendor
# workflows/scripts/board/ verbatim into their own scripts/ dir (`make
# sync-*-board`, foundation-side) and lint their WHOLE tree at defaults:
#
#   find scripts -name '*.sh' -type f -print0 | xargs -0 --no-run-if-empty shellcheck
#
# — no tests/ exclusion, no -e SC1091. Exactly the blind spot: on
# 2026-07-29 the identical SC1091 at test_board_cache.sh:66 was live
# simultaneously in three consumers' `checks`, while the kernel's own gate
# stayed green throughout, because it structurally could not see it. This
# script closes that gap by reproducing the CONSUMER'S command (default
# severity, no exclusions) against the exact file set `make sync-*-board`
# emits, scoped to that set so it stays low-noise and never fights the
# kernel's own whole-tree posture (`make shellcheck` above is UNCHANGED).
#
# SCOPE — the synced file set, byte-for-byte what a sync emits into a
# consumer's scripts/ dir:
#   * workflows/scripts/board/*.sh              (top-level scripts)
#   * workflows/scripts/board/lib/*.sh           (the sourced library)
#   * workflows/scripts/board/tests/*.sh         (the vendored test suite)
#   * workflows/scripts/board/tests/fixtures/*.sh (fake_gh.sh)
# i.e. every *.sh under workflows/scripts/board/ — non-.sh assets (*.md,
# *.json, boards.conf.example) are never part of either lint's input, so a
# plain recursive *.sh find over that one directory IS the synced set.
#
# A finding here is fixed the same way test_board_cache.sh:71 was (temperloop
# #905): a per-line `# shellcheck disable=SC1091` (or whichever code) right
# above the offending line — never a blanket `-e`/`--exclude`, which would
# just reopen this exact gap for the next finding. See that file's own
# comment for the reasoning, and mind the footgun it names: a comment line
# that itself starts with `# shellcheck ` is parsed as a directive attempt,
# so keep any PROSE about shellcheck off a line-initial `# shellcheck `.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
BOARD_DIR="$REPO_ROOT/workflows/scripts/board"

if [[ ! -d "$BOARD_DIR" ]]; then
  echo "board-consumer-shellcheck: no $BOARD_DIR in this checkout — nothing synced, skipping." >&2
  exit 0
fi

# Same PINNED binary as `make shellcheck` (temperloop#567) — a local green
# must mean the same thing as CI's, and the consumer-parity comparison this
# gate exists for is only honest if both lints run the identical shellcheck.
bin="$(bash "$REPO_ROOT/scripts/ensure-shellcheck.sh")" || exit 1

# Consumer parity: default severity, NO */tests/* exclusion, NO -e SC1091 —
# the exact posture named in the header above. --no-run-if-empty mirrors the
# consumer command; the board dir is never empty in this repo, but a synced
# consumer-tree fork could plausibly trim it, and this script should degrade
# the same way the command it mirrors does rather than diverge on that edge.
if find "$BOARD_DIR" -name '*.sh' -type f -print0 \
    | xargs -0 --no-run-if-empty "$bin"; then
  echo "board-consumer-shellcheck: OK — the synced board file set is clean at consumer-parity shellcheck defaults."
  exit 0
else
  rc=$?
  {
    echo
    echo "board-consumer-shellcheck: FAIL — the synced board file set fails shellcheck at"
    echo "  CONSUMER defaults (no */tests/* exclusion, no -e SC1091) even though"
    echo "  'make shellcheck' is green. A vendored copy of this exact tree would red"
    echo "  every consumer's required \`checks\` job (temperloop#905/#915)."
    echo "  Fix at the SOURCE: add a targeted '# shellcheck disable=SCxxxx' directive"
    echo "  right above the flagged line (see test_board_cache.sh:71 for the pattern) —"
    echo "  never a blanket exclusion, which would just reopen this gap."
  } >&2
  exit "$rc"
fi
