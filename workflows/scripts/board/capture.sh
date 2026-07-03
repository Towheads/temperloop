#!/usr/bin/env bash
#
# Capture a noticed-but-not-now item as a tracked board item in ONE call, so a
# defect spotted mid-work never dies as an unanswered "want me to file this?".
#
# This is the source-side half of the dropped-bug capture net (GH #245): the
# live "Capture at source" rule in CLAUDE.md says capture-don't-ask, and this
# script is what makes that cheap. The drain backstop
# (~/.claude/commands/drain-mind.md § Unfiled defects) is the other half.
#
# Routing (per CLAUDE.md § Task workflow "Defect vs enhancement routing"):
#   - DEFECT / trackable work that should exist  -> use this script (board item)
#   - deferred design seam / "consider later"    -> a vault Decision/Context note,
#                                                   NOT this script.
#
#   scripts/capture.sh "Title of the thing"
#   scripts/capture.sh "Title" --body "More detail" --label bug
#   scripts/capture.sh "Foundation tooling bug" --board 4 --label bug
#   scripts/capture.sh "Log rotation" --milestone "Production Live"  # tag a phase
#
# --milestone is a free, concurrent grouping label, NOT a parking gate: it assigns
# the item's native GitHub milestone and LEAVES it in Backlog. Whether a Backlog
# item defers to a future phase is decided downstream by /triage's active-milestone
# intake filter, not by this script flipping a Status — no deferral status is set.
#
# --board selects which Projects-v2 board + repo:
#   3 = "stageFind build"  -> <org>/stageFind   (default)
#   4 = "foundation build" -> <org>/foundation
#
set -euo pipefail

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
source "$SCRIPT_DIR/lib/board.sh"


usage() {
  cat <<'EOF'
usage: capture.sh "<title>" [--body "..."] [--label <l>] [--board 3|4] [--milestone "<m>"]
                  [--rework <regression|spec-miss|flake>]

Capture a noticed-but-not-now item as a tracked board item in one call.
  --body       longer description (defaults to a provenance line)
  --label      add an extra GitHub label (e.g. bug); Operational is always added
               by default — pass --label Foundational to override the work class
  --board      3 = stageFind (default), 4 = foundation
  --milestone  assign a GitHub milestone (free grouping; stays in Backlog)
  --rework     tag the item as rework and record its cause: regression, spec-miss,
               or flake. Applies BOTH the `rework` label and the
               `rework-cause:<cause>` label (created idempotently if missing).
EOF
}

# Handle -h/--help BEFORE the first arg is treated as the title — otherwise
# `capture.sh --help` (no title) files a real junk issue titled "--help" (#366).
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

title="${1:-}"
[ -n "$title" ] || { usage >&2; exit 2; }
# A title starting with `--` is almost certainly a misplaced flag (a typo or a
# forgotten title), not an intended issue title — refuse rather than file junk.
case "$title" in
  --*) { echo "capture.sh: refusing a title that starts with '--' (looks like a misplaced flag): $title"; usage; } >&2; exit 2 ;;
esac
shift

body=""
label=""
board=3
milestone=""
rework=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body)  body="${2:?--body needs a value}"; shift 2 ;;
    --label) label="${2:?--label needs a value}"; shift 2 ;;
    --board) board="${2:?--board needs a value}"; shift 2 ;;
    --milestone) milestone="${2:?--milestone needs a value}"; shift 2 ;;
    --rework) rework="${2:?--rework needs a value}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! repo="$(board_repo "$board")"; then
  echo "--board must be 3 (stageFind) or 4 (foundation), got: $board" >&2
  exit 2
fi

# --rework sugar (F#730): tags a filed item as rework and records WHY, so a
# regression/spec-miss/flake cause is captured at filing time — counts are
# computable from existing data, only the cause needs a label. Applies BOTH the
# `rework` label and a `rework-cause:<cause>` label to the same issue.
rework_labels=()
if [ -n "$rework" ]; then
  case "$rework" in
    regression|spec-miss|flake) : ;;
    *)
      echo "capture.sh: --rework must be one of regression, spec-miss, flake — got: $rework" >&2
      exit 2
      ;;
  esac
  # Idempotent: `gh label create` errors if the label already exists on the
  # repo — ignore that (and any other transient failure) rather than block
  # filing on a label that's already there.
  gh label create "rework" -R "$repo" \
    --color "d93f0b" \
    --description "Work that redoes or corrects prior work (see rework-cause:*)" \
    >/dev/null 2>&1 || true
  gh label create "rework-cause:$rework" -R "$repo" \
    --color "fbca04" \
    --description "Why this rework happened: $rework" \
    >/dev/null 2>&1 || true
  rework_labels=(--label "rework" --label "rework-cause:$rework")
fi

# Default body records provenance so a drained/auto-captured item is traceable.
if [ -z "$body" ]; then
  body="Captured via scripts/capture.sh on $(date +%Y-%m-%d) from a $repo session."
fi

# 1) Create the issue.
# All captures default to Operational: a defect or mid-work item follows an
# established pattern (the Default-Operational rule from work-class-policy.md).
# Foundational is the deliberate exception — pass --label Foundational to override.
create_args=(-R "$repo" --title "$title" --body "$body" --label "Operational")
[ -n "$label" ] && create_args+=(--label "$label")
[ "${#rework_labels[@]}" -eq 0 ] || create_args+=("${rework_labels[@]}")
url=$(gh issue create "${create_args[@]}")
num=$(basename "$url")

# 2+3) Land it on the board in Backlog.
#
# board_capture_item rides the board's "Auto-add to project" workflow: it polls
# the cheap single-item resolve for auto-add to index the new issue, ensures it's
# in Backlog, and only falls back to an explicit item-add + whole-board resolve if
# auto-add never fires — so the GraphQL-heavy add (GH #53) is the rare fallback,
# not every capture. Correct whether or not auto-add is configured.
board_capture_item "$board" "$url" "$num"

# 4) Optional: tag a release phase. Assign the native GitHub milestone as a free,
# concurrent grouping label and LEAVE the item in Backlog — the milestone no longer
# parks anything. Whether a Backlog item defers to a future phase is decided
# downstream by /triage's active-milestone intake filter, not by a Status flip here.
# The milestone must already exist in the repo. board_capture_item left BOARD_*
# resolved for THIS issue, so no extra board read is needed.
if [ -n "$milestone" ]; then
  if board_set_milestone "$board" "$num" "$milestone"; then
    echo "Captured $url -> board $board Backlog, milestone '$milestone' (#$num)"
    exit 0
  fi
  echo "warning: created #$num but could not set milestone '$milestone'" \
       "(does the milestone exist in $repo?) — left in Backlog with no milestone" >&2
fi

echo "Captured $url -> board $board Backlog (#$num)"
