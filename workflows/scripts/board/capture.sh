#!/usr/bin/env bash
#
# Capture a noticed-but-not-now item as a tracked board item in ONE call, so a
# defect spotted mid-work never dies as an unanswered "want me to file this?".
#
# This is the source-side half of the dropped-bug capture net (GH #245): the
# live "Capture at source" rule in CLAUDE.md says capture-don't-ask, and this
# script is what makes that cheap. The drain backstop
# (~/.claude/commands/tidy.md § Unfiled defects) is the other half.
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
#   scripts/capture.sh "Board adapter caching bug" --repo kernel      # kernel tracker
#   scripts/capture.sh "Not sure if kernel or overlay" --repo ambiguous
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
# --repo is a conscious-routing peer to --board (F#808, Guard #3 of the
# kernel-vs-overlay routing rule — CLAUDE.kernel.md § Kernel vs overlay
# routing rule). It overrides --board when given:
#   --repo kernel       route to the temperloop ISSUES-ONLY tracker
#                        (logical board 7 — registered in lib/board.sh's
#                        board_repo/board_backend built-in maps, see
#                        ISSUES-ONLY-BACKEND.md) instead of a Projects-v2
#                        board. Use when the capture IS kernel-domain
#                        machinery (board adapter, build/sweep spine,
#                        install/doctor, quality gates — the "stranger test"
#                        from the routing rule).
#   --repo ambiguous     the capture is foundation-domain (foundation's own
#                        pipeline machinery) but the caller can't tell
#                        kernel vs overlay. Per the routing rule's ambiguity
#                        clause ("Ambiguous foundation-domain captures
#                        default to kernel"), this ALSO routes to board 7 —
#                        a distinct spelling from `kernel` purely for
#                        provenance: the filed issue's body records that the
#                        route was a DEFAULT, not a deliberate call, so a
#                        human triaging the kernel tracker can re-route it
#                        to --board 4 if the default guessed wrong. No TTY
#                        prompt is implemented — an interactive
#                        disambiguation prompt is optional per the issue
#                        contract; the required part is that the default
#                        (kernel) and its rationale are documented here and
#                        in ISSUES-ONLY-BACKEND.md.
# Neither flag changes the plain `--board 3` / `--board 4` default behavior:
# an unambiguous capture with no --repo still goes exactly where it always
# did.
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-capture}"

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

# Canonical default sink for the append-only issue-touches log (F#916/#919,
# epic #916 issue-touch-stream) — computed ONCE as a module constant, same
# pattern as scripts/claim.sh's CLAIMS_RAW_DIR_DEFAULT. capture.sh runs from
# CONSUMING checkouts too (stageFind, worker cwds symlink/copy this script), so
# the sink is pinned to the foundation checkout's own raw lake regardless of
# cwd, exactly like claim.sh's claims log. ISSUE_TOUCHES_RAW_DIR overrides it
# (tests only).
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's record shape is documented at
# issue_touch_log_emit below).
ISSUE_TOUCHES_RAW_DIR_DEFAULT="$HOME/dev/foundation/meta/data/raw"

# Append one JSONL record of this capture to the append-only issue-touches
# stream (F#916/#919) — the `kind:"capture"` half of the stream; `pr-open` and
# `merge` are emitted separately by emit-issue-touch.sh from build.md's
# orchestrator steps (3f/4d). Claim touches are DELIBERATELY NOT emitted here
# or anywhere in this script — the existing claims-<YYYY-MM>.jsonl stream
# (claim.sh's claim_log_emit) already covers them and is unioned at read time.
#
# Sink resolution, host/session derivation, and failure posture all mirror
# scripts/claim.sh's claim_log_emit EXACTLY: `|| true`-isolated at the call
# site, WARN (never fail) on an unwritable/missing sink dir — a telemetry
# emit must never block a real capture already committed via `gh issue
# create` above. See claim_log_emit's own header comment for the fuller
# rationale (all-boards-by-design, single-host coverage caveat) — identical
# here.
issue_touch_log_emit() {  # $1=repo $2=issue-number $3=kind (capture|pr-open|merge)
  local dir file ts rec host sess
  dir="${ISSUE_TOUCHES_RAW_DIR:-$ISSUE_TOUCHES_RAW_DIR_DEFAULT}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file="$dir/issue-touches-${ts%-*}.jsonl"   # ts%-* strips DDThh:mm:ssZ, leaving YYYY-MM
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "capture.sh: WARN issue-touches log dir unavailable: $dir (issue captured; NOT logged to the raw lake)" >&2
    return 0
  fi
  host="${SUBSET_HOST_LABEL:-$(hostname -s)}"
  sess="${CLAUDE_CODE_SESSION_ID:-}"
  rec=$(printf '{"schema_version":"1","ts":"%s","repo":"%s","issue":%s,"session_id":"%s","host":"%s","kind":"%s"}' \
    "$ts" "$1" "$2" "$sess" "$host" "$3")
  printf '%s\n' "$rec" >>"$file" 2>/dev/null \
    || echo "capture.sh: WARN failed to append issue-touches log record to $file (issue captured; not logged)" >&2
}

usage() {
  cat <<'EOF'
usage: capture.sh "<title>" [--body "..."] [--label <l>] [--board 3|4] [--milestone "<m>"]
                  [--rework <regression|spec-miss|flake>] [--repo kernel|ambiguous]
   or: capture.sh --title "<title>" [ ...same flags... ]

Capture a noticed-but-not-now item as a tracked board item in one call.
  --title      the issue title, as a flag alias for the positional first arg
               (pass EITHER positionally OR via --title, not both)
  --body       longer description (defaults to a provenance line)
  --label      add an extra GitHub label (e.g. bug); Operational is always added
               by default — pass --label Foundational to override the work class
  --board      3 = stageFind (default), 4 = foundation
  --milestone  assign a GitHub milestone (free grouping; stays in Backlog)
  --rework     tag the item as rework and record its cause: regression, spec-miss,
               or flake. Applies BOTH the `rework` label and the
               `rework-cause:<cause>` label (created idempotently if missing).
  --repo       kernel = route to the temperloop issues-only tracker
               (overrides --board); ambiguous = foundation-domain capture,
               kernel-vs-overlay unclear -> defaults to kernel per the
               routing rule's ambiguity clause (see ISSUES-ONLY-BACKEND.md)
EOF
}

# Handle -h/--help BEFORE the first arg is treated as the title — otherwise
# `capture.sh --help` (no title) files a real junk issue titled "--help" (#366).
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# Title source: the positional first arg OR `--title <value>` (foundation#1227).
# Every sibling field is a flag, so the odd-one-out positional kept getting
# mis-passed as `--title` (misuse recurred 2026-07-07 / 2026-07-17 with the
# lesson already banked) — so accept both, but require EXACTLY ONE source. A
# leading `--` arg is NOT taken as the positional title (it's a flag, including
# `--title` itself, parsed in the loop below); a bare leading arg is.
title=""
positional_title=0
case "${1:-}" in
  '' | --*) : ;;                    # no positional title (flags-only, or empty)
  *) title="$1"; positional_title=1; shift ;;
esac

body=""
label=""
board=3
milestone=""
rework=""
repo_route=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      [ "$positional_title" -eq 0 ] || { echo "capture.sh: pass the title EITHER positionally OR via --title, not both" >&2; exit 2; }
      title="${2:?--title needs a value}"; shift 2 ;;
    --body)  body="${2:?--body needs a value}"; shift 2 ;;
    --label) label="${2:?--label needs a value}"; shift 2 ;;
    --board) board="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
    --milestone) milestone="${2:?--milestone needs a value}"; shift 2 ;;
    --rework) rework="${2:?--rework needs a value}"; shift 2 ;;
    --repo)  repo_route="${2:?--repo needs a value}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$title" ] || { echo "capture.sh: a title is required (positional or --title)" >&2; usage >&2; exit 2; }
# A title starting with `--` is almost certainly a misplaced flag (a typo or a
# forgotten value), not an intended issue title — refuse rather than file junk.
case "$title" in
  --*) { echo "capture.sh: refusing a title that starts with '--' (looks like a misplaced flag): $title"; usage; } >&2; exit 2 ;;
esac

# --repo kernel/ambiguous routing (F#808, Guard #3 of the kernel-vs-overlay
# routing rule) — overrides --board. `ambiguous` routes to the SAME board as
# `kernel` but records a distinct provenance note in the filed issue's body
# (route_note, appended after the default-body block below) so the default
# is legible to a later human triage pass, not silently indistinguishable
# from a deliberate `--repo kernel` call. See ISSUES-ONLY-BACKEND.md.
KERNEL_BOARD=7  # temperloop issues-only tracker; see lib/board.sh's board_repo/board_backend built-in maps
route_note=""
if [ -n "$repo_route" ]; then
  case "$repo_route" in
    kernel)
      board="$KERNEL_BOARD"
      ;;
    ambiguous)
      board="$KERNEL_BOARD"
      route_note="[capture.sh --repo ambiguous: foundation-domain capture auto-routed to the kernel tracker per the kernel-vs-overlay routing rule's ambiguity default (CLAUDE.kernel.md § Kernel vs overlay routing rule — \"Ambiguous foundation-domain captures default to kernel\"). Re-file with --board 4 if this turns out to be overlay-only material.]"
      ;;
    *)
      echo "capture.sh: --repo must be 'kernel' or 'ambiguous', got: $repo_route" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

if ! repo="$(board_repo "$board")"; then
  echo "--board must be 3 (stageFind), 4 (foundation), 7 (kernel, or use --repo kernel), or a boards.conf-registered board, got: $board" >&2
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
# --repo ambiguous provenance (see routing block above) — appended regardless
# of whether --body was given, so the auto-routing rationale is always
# visible on the filed issue, not just when the caller took the default body.
[ -z "$route_note" ] || body="$body

$route_note"

# Work-class labels (Operational/Foundational, see claude/work-class-policy.md)
# may not exist yet on a fresh-history kernel/adopter repo — `gh issue create
# --label` aborts with "could not add label: '<name>' not found" if the label
# is missing, so no issue is created at all. Ensure whichever work-class
# label(s) are about to be applied exist first, via the existing idempotent,
# process-memoized helper (_board_issues_ensure_label, lib/board.sh:723-732 —
# sourced above at capture.sh:80) rather than a second label-create mechanism.
# Where labels already exist (any composed/overlay checkout), the helper's
# `gh label create || true` is a harmless no-op.
#
# NOTE: --label Foundational SUBSTITUTES the default Operational work-class
# label below (a mutually-exclusive binary — #49), so an issue carries exactly
# one work-class label. Ensuring Operational exists here regardless is a
# harmless no-op when it ends up unapplied.
_board_issues_ensure_label "$repo" "Operational" "0e8a16" \
  "Work class: follows an established, fully-specifiable pattern — fully autonomous (claude/work-class-policy.md)"
case "$label" in
  Foundational)
    _board_issues_ensure_label "$repo" "Foundational" "5319e7" \
      "Work class: new capability/architecture, operator judgment required (claude/work-class-policy.md)"
    ;;
esac

# 1) Create the issue.
# All captures default to Operational: a defect or mid-work item follows an
# established pattern (the Default-Operational rule from work-class-policy.md).
# Foundational is the deliberate exception — pass --label Foundational to override.
#
# Work-class labels are a mutually-exclusive binary (claude/work-class-policy.md):
# an issue carries EXACTLY ONE of Operational/Foundational. So a --label naming a
# recognized work-class value SUBSTITUTES the default Operational rather than
# appending alongside it (the #49 dual-label defect). A non-work-class --label
# (e.g. bug) still appends as an extra label on top of the default Operational.
case "$label" in
  Operational|Foundational) work_class="$label" ;;
  *)                        work_class="Operational" ;;
esac
create_args=(-R "$repo" --title "$title" --body "$body" --label "$work_class")
{ [ -n "$label" ] && [ "$label" != "$work_class" ]; } && create_args+=(--label "$label")
[ "${#rework_labels[@]}" -eq 0 ] || create_args+=("${rework_labels[@]}")
url=$(gh issue create "${create_args[@]}")
num=$(basename "$url")

# Append one issue-touch record (F#916/#919) now that the issue is real —
# `|| true`-isolated so a missing/unwritable raw lake never fails a capture
# that already succeeded. See issue_touch_log_emit's header comment above.
issue_touch_log_emit "$repo" "$num" "capture" || true

# 2+3) Land it on the board in Backlog.
#
# board_capture_item rides the board's "Auto-add to project" workflow: it polls
# the cheap single-item resolve for auto-add to index the new issue, ensures it's
# in Backlog, and only falls back to an explicit item-add + whole-board resolve if
# auto-add never fires — so the GraphQL-heavy add (GH #53) is the rare fallback,
# not every capture. Correct whether or not auto-add is configured.
#
# That fallback (board_create_on_board -> board_create_many, in lib/board.sh) is
# exactly the path a BURST of serial capture.sh invocations hits when auto-add
# is off/slow, and it used to be O(N) in the burst size (foundation #1225): every
# invocation's board_add_to_board unconditionally busted the cross-process items
# cache the NEXT invocation would have reused, so N serial captures inside one
# BOARD_CACHE_TTL window paid N live whole-board resolves instead of sharing ~1.
# Two fixes now live in lib/board.sh, not here (no capture.sh code needed):
# board_add_to_board splices the newly-added item's stub into the warm cache
# instead of busting it (_board_cache_patch_add), and board_create_many's
# index-wait retry loop is now pre-flight budget-guarded — DEFAULTING TO ABORT
# (not the general guard's warn-only default) on a near-empty GraphQL budget, so
# a burst that would have silently drained the budget instead fails loud through
# the SAME truthful-failure contract the `board_capture_item` check below already
# handles (non-zero + BOARD_UNLANDED_ISSUES) rather than stranding issues off-board.
#
# board_capture_item now returns non-zero when the item never actually lands
# (foundation #1226 — the Projects-v2 index race board_create_many's header
# comment documents). Called EXPLICITLY under `set -euo pipefail`, not bare: a
# bare call would abort the script mid-flight on that failure with no message
# of its own (a silent, unexplained abort instead of the old false "Captured
# -> Backlog" success line — an improvement over the bug, but still not the
# actionable report a caller needs, and it would skip the milestone step
# below with no explanation). Handle it explicitly instead: report the
# created-but-not-landed issue loudly with a concrete next step, and exit
# non-zero — NEVER fall through to the "Captured -> Backlog" line for an item
# that didn't land.
if ! board_capture_item "$board" "$url" "$num"; then
  echo "capture.sh: created $url (#$num) but it did NOT land on board $board" \
       "— the board card is missing or unstatused (a Projects-v2 index race);" \
       "next step: re-run \`board_capture_item $board '$url' $num\` (after" \
       "sourcing lib/board.sh) once indexing catches up, or add/status it on" \
       "the board by hand" >&2
  exit 1
fi

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
