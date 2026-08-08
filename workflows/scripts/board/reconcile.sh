#!/usr/bin/env bash
#
# Surface board DRIFT. Two independent lenses, selected by flag:
#
#   reconcile.sh [--board N]            (default) MARKER drift — board In-Progress
#                                       vs. the local tmux @claimed_issue markers
#                                       for THIS host. Read-only.
#          ... --fix                    also auto-applies the one SAFE marker
#                                       repair (THIS window's stale marker whose
#                                       issue is provably closed/merged).
#   reconcile.sh [--board N] --status   STATUS drift — board Status vs. GitHub
#                                       reality (closed/merged backing issues/PRs,
#                                       orphaned In-Progress, and — on the
#                                       issues-only backend — the closed-issue
#                                       tail the board read cannot see).
#                                       Read-only report.
#          ... --status --fix           also auto-applies the one SAFE repair
#                                       (terminal-but-not-Done → Done).
#   reconcile.sh [--board N] --labels   LABEL hygiene — orphaned issues-only
#                                       `fnd:` tracker labels. Dry-run report
#                                       (zero writes) by default.
#          ... --labels --apply         also deletes/strips the candidates.
#          ... --labels --unattended    implies --apply, AND records the
#                                       auto-taken apply to the pending-
#                                       decisions surface (ask-at-checkin).
#
# ─── Lens 1: marker drift (default) ──────────────────────────────────────────
# Background. scripts/claim.sh stamps BOTH the board (Status=In Progress +
# Host/Session=`<host>:<sess8>`) AND a per-window tmux marker (@claimed_issue).
# scripts/release.sh clears the marker and — since temperloop#979, ONLY on an
# issues-only board, ONLY when passed `<issue#> --board <N>`, and ONLY for a
# PARKED (not In-Progress) item this same session stamped — that item's claim
# stamp; it still never un-claims the board STATUS ("Park, don't abandon").
# So the two can legitimately drift, and until now nothing surfaced that drift.
# This command does — for the current host only.
#
# It reports two drift directions, plus an all-clear when neither applies:
#
#   1) marker-without-board — a tmux window holds an @claimed_issue marker for an
#      issue that is NOT In Progress on the board, or is In Progress but stamped
#      to a DIFFERENT host. The local marker is stale (e.g. the board item was
#      moved to Done elsewhere, or you never owned it).
#
#   2) board-without-marker — the board has an item In Progress stamped to THIS
#      host, but no live tmux window holds its @claimed_issue marker. Claimed on
#      the board with no local marker (e.g. after release.sh, or a dead session).
#
# ─── Lens 1 repair: --fix (temperloop#748) ───────────────────────────────────
# `--fix` on the marker lens applies ONE narrowly-scoped, provably-safe repair:
# it clears THIS WINDOW's own claim marker, and only when that marker names an
# issue that is BOTH (a) marker-without-board drift and (b) PROVABLY TERMINAL
# (its backing issue/PR reads CLOSED or MERGED on GitHub). The clear routes
# through lib/claim_marker.sh's `claim_marker_clear` — the same primitive
# release.sh uses — so there is exactly one marker-clearing implementation.
#
# Three boundaries are deliberate and NOT negotiable:
#
#   * OPT-IN. Without `--fix` this lens still only reports; it mutates nothing.
#
#   * THIS WINDOW ONLY. The report scans every window on the tmux server, but
#     the repair touches only the caller's own window ($TMUX_PANE / the caller's
#     own cmux workspace) — the GH #297 doctrine every marker write in this
#     toolkit obeys: never brand or un-brand a window you do not own, because a
#     concurrent session may be living in it. A stale marker in another window
#     is still REPORTED; clearing it means running this from that window.
#
#   * PROVABLY-TERMINAL ONLY, and never the converse class. A marker whose
#     issue is still OPEN is left alone (the work may be live). The entire
#     `board-without-marker` class is NEVER repaired — not cleared, and above
#     all never re-stamped: temperloop#719 showed that class produces FALSE
#     stranded-claim signals (a demonstrably LIVE session's window marker had
#     simply been clobbered by a later claim), so acting on it risks stomping a
#     live peer session. Detect and report it; never repair it.
#
# This is the LOCAL-MARKER half of the post-terminal claim rot only. The board
# half — a closed issue retaining `fnd:status:in-progress` / `fnd:host/session:*`
# — is Lens 3 (--labels) classes (h)/(j), deliberately separate (temperloop#744).
#
# K#275 is untouched: `release.sh <n>` still refuses to clear a non-latest
# claim. This repair never forces such a release — it clears whatever THIS
# window holds, exactly like an argument-less `release.sh`, and only after
# proving that marker names terminal work.
#
# "THIS host" matches claim.sh's logic:
#   ${SUBSET_HOST_LABEL:-$(hostname -s)}
# and the board stamp format `<host>:<sess8>` — an item is "stamped to this host"
# when its Host/Session value's host part (before the first ':') equals it.
#
# ─── Lens 2: status drift (--status) ─────────────────────────────────────────
# The board can fall out of sync with GitHub itself — work lands via a PR that
# auto-adds to the board but no step ever moves the item to Done; an issue is
# closed by hand while its board item still reads Ready; a claim half-lands and
# leaves an In-Progress item with no owner stamp (GH #103). `--status` resolves
# the board, then bulk-reads issue+PR state via two REST list calls (the item-list
# JSON carries no state) and classifies each item into three drift classes:
#   (a) terminal-but-not-Done — backing issue/PR is CLOSED or MERGED yet the item
#       is not Done. AUTO-FIXABLE: `--fix` moves it to Done (the work is provably
#       complete).
#   (c) orphaned In-Progress — status In Progress with an empty Host/Session
#       stamp (a claim with no owner). REPORT-ONLY: repair needs a human park
#       decision, so it is never auto-moved.
#   (d) stale claim — In Progress, stamped `<host>:<sess>` to THIS host, but that
#       session's transcript is dead (absent, or untouched > RECONCILE_STALE_AFTER_SECS
#       — GH #85). A stranded claim a dead run left behind. REPORT-ONLY (never
#       auto-released — that's a human park decision; the draining session's own
#       claims self-exclude because their transcript mtime is current).
#   (f) foreign claim — In Progress, stamped to ANOTHER host, whose session
#       liveness can't be checked from here. REPORT-ONLY, surfaced for the owning
#       host to reconcile on its next sweep; never released from this machine.
#       A foreign claim whose owning host never drains again (decommissioned /
#       abandoned) would strand forever, so a foreign claim whose backing issue/PR
#       has had NO activity for > RECONCILE_FOREIGN_STALE_AFTER_SECS (issue.updatedAt,
#       read from the same bulk list — no extra call) is split into a louder
#       "foreign claims (STALE — escalate)" bucket. Still REPORT-ONLY: a human
#       verifies the host is gone, then release.sh by hand (GH #152, follow-up to #85).
#       Caveat: updatedAt measures ISSUE liveness, not CLAIMANT liveness — there is
#       no cross-host claimant-alive signal (that is why this is the foreign path).
#       So incidental issue activity (a bot, a cross-ref, a label) can keep a truly
#       stranded claim in the PLAIN foreign bucket; the escalation is a best-effort
#       net, and its miss degrades to pre-#152 behaviour (still surfaced), never to
#       a wrongful auto-release. Report-only is what makes the proxy's fuzz safe.
#   (?) unresolved — the item's number is in neither list (e.g. cross-repo or past
#       the fetch cap). REPORT-ONLY.
# REST list calls are flat-cost (2 per run, not per-item) and do NOT touch the
# Projects-v2 GraphQL budget that single-item GraphQL would.
#
# ─── Lens 2, the CLOSED-ISSUE TAIL (temperloop#1410) ─────────────────────────
# The five classes above all start from a BOARD ITEM. On the Projects-v2 backend
# that is a complete candidate population for terminal drift: closing an issue
# does not remove its project card, so a closed-but-not-Done issue is still in
# `board_item_list` and class (a) catches it.
#
# On the ISSUES-ONLY backend it is NOT complete, and that made this lens
# structurally blind. There, the board item IS the issue and the whole-board read
# (`_board_issues_item_list`) is defined as the OPEN issue set — "Done" is not a
# label, it is the issue being CLOSED. So a closed issue that still carries a
# residual `fnd:status:in-progress` label, or a stranded `fnd:host/session:*`
# claim stamp, is not merely misclassified: it is ABSENT from the item list
# entirely, and `--status` happily reported "In sync" over it. That is exactly
# the drift `claude/commands/build.md` 4d leans on this lens to catch after a
# merged PR's bare `Closes #N` closes an issue behind the adapter's back.
#
# The fix is at the lens level, not per-board: the candidate population for
# status drift is `board items ∪ the closed-issue tail`, and the tail is read
# from the SAME `issue list --state all` call this lens already makes (no extra
# gh call — it just asks for `labels,title` too). Two more classes, both
# issues-only by construction (the `fnd:` label vocabulary only exists there):
#   (k) residual status label on a closed issue — a `fnd:status:*` label on an
#       issue that is CLOSED. Done on this backend is "closed + NO status label"
#       (there is deliberately no `fnd:status:done`), so any status label on a
#       closed issue is drift. This is class (a)'s issues-only analogue.
#   (l) stranded claim stamp on a closed issue — a `fnd:host/session:*` label on
#       a CLOSED issue: a cross-session claim lock that can never be released,
#       indistinguishable from a live claim to `issue-state.sh resolve` and to
#       the foreign-claim bucket above. This is the same population Lens 3's
#       class (j) reports, surfaced here so `--status` cannot silently disagree
#       with `--labels` about whether the board is clean.
# Both are REPORT-ONLY here, deliberately: the repair already exists, exactly
# once, in Lens 3 (`--labels --apply`, with its per-issue re-check immediately
# before each write). `--status --fix` still applies only the terminal→Done
# move; it never grows a second label-stripping implementation.
#
# ─── Lens 3: label hygiene (--labels) ────────────────────────────────────────
# The issues-only backend (board_backend == "issues", e.g. board 7 — the kernel
# tracker itself) rides ALL item state on `fnd:`-namespaced repo labels rather
# than Projects-v2 fields (see lib/board.sh's issues-only-backend section and
# ISSUES-ONLY-BACKEND.md). Five label classes accumulate cruft over the
# tracker's lifetime that nothing else sweeps (lib/board.sh's
# `_board_issues_stamp_field` header documented the first of them):
#
#   (g) orphaned host/session labels — a `fnd:host/session:<host>:<sess8>`
#       repo label object left behind after its claiming issue closed (or was
#       re-claimed under a different stamp). "Orphaned" = attached to ZERO
#       OPEN issues — a claim's label on an open issue is always live and is
#       NEVER a delete candidate. Distinct label VALUES accumulate one repo
#       label object per claim ever made; `_board_issues_ensure_label`
#       memoizes creation but nothing ever removes the object.
#   (h) stale status labels on closed issues — a `fnd:status:*` label left on
#       an issue that is now CLOSED. Closing an issue (via `gh issue close`,
#       or via a merged PR's `Closes #N`) never strips its status label — only
#       `_board_issues_set_field`'s own Status-field write path does that, and
#       a PR close bypasses it entirely.
#   (j) stranded claim stamps on closed issues — a `fnd:host/session:*` label
#       left ON a CLOSED issue (temperloop#744). Distinct from (g), and NOT
#       covered by it: (g) deletes a repo LABEL OBJECT only when it is attached
#       to zero OPEN issues, so as long as ANY open issue still wears that stamp
#       (one session claimed several items and one is still live) the label
#       object is correctly kept — and every CLOSED issue wearing it stays
#       stranded forever. A stranded stamp is a cross-session claim lock that
#       can never be released: `issue-state.sh resolve` derives
#       `claimed-elsewhere` from exactly this label, and it is indistinguishable
#       from a live claim. --apply STRIPS the label from the closed ISSUE (a
#       per-issue `issue edit --remove-label`); it NEVER deletes the label
#       OBJECT — that stays (g)'s job, so a stamp still worn by a live open
#       claim survives as an object. The root-cause half is `lib/board.sh`'s
#       `_board_issues_set_field` Done arm, which now clears the stamp as part
#       of reaching Done; this class is the backstop for every close that
#       BYPASSES the adapter (a merged PR's native `Closes #N`, a hand
#       `gh issue close`, the web UI) — the same adapter-bypass leak (h) exists
#       for, and the reason a root-cause-only fix would not sweep the backlog.
#   (m) PARKED claim stamps on OPEN issues — a `fnd:host/session:*` label on an
#       OPEN issue whose `fnd:status:*` is NOT in-progress (temperloop#979).
#       The park path's blind spot, and the one class none of (g)/(h)/(j) can
#       reach: the issue is OPEN, so (h)/(j) — both scoped to CLOSED issues —
#       skip it, while the label object still has an open-issue attachment (this
#       very one), so (g) correctly refuses to delete it. Yet a claim stamp on a
#       Ready/Backlog item is drift BY CONSTRUCTION: the board reads it as owned
#       by a session that is gone — the cross-session-lock confusion the stamp
#       exists to prevent — and `issue-state.sh resolve` cannot tell it from a
#       live claim. Deliberately NOT extended to an In-Progress issue: there the
#       stamp is a LIVE claim HELD until Done (K#275), the sanctioned flow, not
#       drift. --apply STRIPS the label from the OPEN issue (a per-issue `issue
#       edit --remove-label`, behind the same immediate re-check every other
#       class uses — the issue must still be open, still carry that exact label,
#       and still not be In Progress); it NEVER deletes the label OBJECT, which
#       stays (g)'s job. The root-cause half is `release.sh`'s own board-side
#       clear (temperloop#979); this class is the backstop for every park that
#       never ran it — or ran it from a LATER session, whose foreign stamp
#       release.sh deliberately refuses to touch — the same report-then-sweep
#       shape (h)/(j) have for adapter-bypassing closes, and the reason the
#       issue named it the more robust of the two halves.
#   (i) unstatused open issues — an OPEN issue carrying NO `fnd:status:*` label
#       at all (temperloop#376). Status is emulated by that label, so such an
#       issue reads as `.status = ""` in board_item_list — and /triage's
#       Backlog intake (Adapter A keeps only `.status == Backlog`) SILENTLY
#       SKIPS it, so a genuine defect falls out of the pipeline with no error.
#       The capture path (capture.sh → board_capture_item) already stamps
#       fnd:status:backlog on everything it files; this class is the backstop
#       for an issue that reached the tracker by any OTHER route (a hand
#       `gh issue create`, an older/foreign tool). --apply BACKFILLS
#       fnd:status:backlog — the safe default: it only makes the issue visible
#       to the next Backlog sweep, and is reversible via a later status write.
#
# --labels alone is a REPORT — it prints every candidate list and its
# counts with ZERO writes (the interactive default, matching --status's
# report-only default). --apply performs the deletes/strips; a SECOND --apply
# run is idempotent (the just-deleted/-stripped labels are no longer
# candidates, so it reports/applies zero changes). Every delete/strip is
# preceded by an IMMEDIATE re-check (a fresh `issue list`/`api` read, not the
# earlier bulk scan) so a claim or a status write that lands in the gap
# between scan and apply is never destroyed — see label_reconcile_main's own
# comments for the exact re-check call. No non-`fnd:`-prefixed label is ever
# read for deletion candidacy, listed, touched, or modified by this lens.
#
# --unattended additionally (a) implies --apply (this sweep's ratified default
# under NO live operator is to apply, unlike the report-only stale-claim sweep
# above — a deleted label object is trivially recoverable via `gh label
# create`, and a backfilled status label is reversible via a later status
# write, so both auto-takes are safe) and (b) records the auto-taken apply to
# the pending-decisions surface (`claude/CLAUDE.md` § Unattended
# pending-decisions surface) via `workflows/scripts/lib/knowledge_store.sh`'s
# `ks_append` — best-effort: a missing/unavailable knowledge store degrades to
# a stderr notice and never fails the sweep itself.
#
# Usage:
#   scripts/reconcile.sh                       # marker drift report; exits 0
#   scripts/reconcile.sh --fix                 # + clear THIS window's marker if
#                                              #   it names provably-terminal work
#   scripts/reconcile.sh --board 4 --status    # status drift report; exits 0
#   scripts/reconcile.sh --board 4 --status --fix   # + apply terminal→Done
#   scripts/reconcile.sh --board 7 --labels    # label hygiene report; exits 0
#   scripts/reconcile.sh --board 7 --labels --apply         # + apply
#   scripts/reconcile.sh --board 7 --labels --unattended    # apply + ledger
#
# Test seams (overridable AFTER sourcing, mirroring lib/claim_marker.sh and
# lib/board.sh): board reads/writes route through board.sh's `_board_gh`; tmux
# marker reads route through `_reconcile_tmux` (defined below). A test overrides
# both to inject canned data with zero network and zero real tmux server.
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-reconcile}"

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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"
# The marker-repair path (--fix on Lens 1) clears markers through the SAME
# primitive release.sh uses — claim_marker_clear — rather than reimplementing a
# second marker-clearing code path. claim_marker_peek reads this window's marker
# without clearing it, for the safety gates. Sourcing is side-effect-free.
# shellcheck source=scripts/lib/claim_marker.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/claim_marker.sh"

# reconcile is the board↔marker CONSISTENCY check — its whole job is to surface
# drift, so it MUST read the board LIVE. A drift detector fed cached data is
# self-defeating.
#
# HOW THE LIVE READ IS GUARANTEED NOW. This used to be an explicit
# `export BOARD_CACHE_TTL=0` pin against board.sh's default-ON cross-process
# read cache (GH #93). That cache was removed with the Projects-v2 arm it
# relieved (ADR 0004, epic temperloop#524), so the pin became a no-op and is
# gone. The live read is now guaranteed STRUCTURALLY rather than by a setting:
# board.sh's issues-only whole-board read is a live `gh issue list` unless a
# caller has BOTH set `board.<N>.cache=on` AND sourced `lib/cache.sh` in the
# same process — and this script never sources cache.sh, so the
# `declare -F cache_read` probe in `_board_issues_item_list` always fails here
# and the read stays live no matter what a shared `boards.conf` says.
#
# THAT IS THE CONTRACT, AND IT IS LOAD-BEARING: reconcile.sh must never source
# lib/cache.sh, and any future cache layer added ahead of the live read must be
# bypassed here too. Two tests pin it — tests/test_reconcile.sh's Lens 3
# behaviorally, and tests/test_cache_command_wiring.sh section 3 by static
# inspection, anchored to a real sourcing line so this comment naming the path
# plainly does not itself trip it (temperloop#1152).

PROJECT_NUMBER=3
# --fix: apply the one safe repair of whichever lens is selected — Lens 2's
# terminal→Done board move (--status --fix), or Lens 1's this-window stale-marker
# clear (the default marker lens). Set by the execute-guard or by a sourcing test
# before it calls status_reconcile_main / reconcile_main.
FIX=0
# Page size for the issue/PR state bulk-reads. A board larger than this would
# under-read; status_reconcile_main warns when a list hits the cap (no silent cap).
STATE_LIMIT=1000
# --labels --apply: perform the delete/strip candidates (default 0 = report
# only, zero writes). --labels --unattended forces this to 1 (§ Lens 3 above).
LABELS_APPLY=0
# --labels --unattended: apply (forces LABELS_APPLY=1) AND record the
# auto-taken apply to the pending-decisions surface. Set by the execute-guard
# or by a sourcing test before it calls label_reconcile_main.
LABELS_UNATTENDED=0
# Page size for the label-list / closed-issues bulk reads (§ Lens 3). A repo
# with more than this many `fnd:` labels or closed issues would under-read;
# label_reconcile_main warns when a list hits the cap (no silent cap).
LABEL_LIMIT=1000
# Staleness cutoff for a same-host claim whose session transcript EXISTS but
# hasn't been touched recently (an absent transcript is dead immediately). A
# claim stamped to this host whose session has been idle longer than this is a
# stale-claim candidate (GH #85). Default 24h; override for tests / tuning.
RECONCILE_STALE_AFTER_SECS="${RECONCILE_STALE_AFTER_SECS:-86400}"
# Escalation cutoff for a FOREIGN claim (stamped to another host, so unverifiable
# here). When the backing issue/PR has had no activity (issue.updatedAt) for longer
# than this, the foreign claim is surfaced as a STALE escalation candidate — likely
# stranded by a host that will never drain again (GH #152). Still report-only.
# Default 14 days; deliberately far longer than the same-host stale cutoff (a foreign
# host may legitimately work an item for days before its drain catches it).
RECONCILE_FOREIGN_STALE_AFTER_SECS="${RECONCILE_FOREIGN_STALE_AFTER_SECS:-1209600}"

# --- tmux marker read seam ------------------------------------------------
# The ONE indirection every tmux read routes through, so a test can override it
# to replay canned `@claimed_issue` values without a real tmux server. Mirrors
# lib/claim_marker.sh's `_reconcile_tmux` analogue (`_claim_marker_tmux`).
_reconcile_tmux() { tmux "$@"; }

# --- session-liveness read seam (GH #85) ----------------------------------
# Decide whether a claim's session `<sess8>` is still LIVE on THIS host, by the
# mtime of its Claude Code transcript. A live session appends to its transcript
# constantly, so a recent mtime == alive; an absent transcript or one untouched
# beyond RECONCILE_STALE_AFTER_SECS == a dead/stranded session. The ONE seam every
# liveness check routes through, so a test overrides it to inject live/dead with
# zero filesystem dependence (mirrors _reconcile_tmux). Returns 0 (live) / 1 (dead).
# Self-exclusion falls out for free: the draining session's own transcript mtime
# is "now", so its own claims are never flagged.
_reconcile_session_live() {
  local sess="$1" newest now
  [ -n "$sess" ] || return 1
  # Newest matching transcript's mtime (epoch), or empty if none. Contained in a
  # subshell so `nullglob` (no-match → empty, not the literal pattern) and the
  # glob loop never leak shell state. Portable mtime: GNU `stat -c`, BSD `stat -f`.
  newest="$(
    shopt -s nullglob
    dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"; max=0
    for f in "$dir"/*/"$sess"*.jsonl; do
      mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || continue
      [ -n "$mt" ] && [ "$mt" -gt "$max" ] && max="$mt"
    done
    printf '%s' "$max"
  )"
  [ "${newest:-0}" -gt 0 ] || return 1            # no transcript → dead
  now="$(_reconcile_now)"
  [ "$((now - newest))" -le "$RECONCILE_STALE_AFTER_SECS" ]
}

# --- clock + timestamp seams (GH #152) ------------------------------------
# "Now" routed through one seam so a test injects a fixed epoch (mirrors
# _reconcile_tmux / _reconcile_session_live) and foreign-age cases are hermetic.
_reconcile_now() { date +%s; }

# Parse an ISO-8601 UTC timestamp ("2026-06-07T12:00:00Z", as gh emits updatedAt)
# to epoch seconds, portably: GNU `date -d` first, then BSD `date -j -f`. Prints
# nothing on a missing/unparseable value so the caller can fail safe (never escalate
# on bad data). TZ=UTC is FORCED on both branches: BSD's `date -j -f` treats the
# trailing 'Z' as a literal, not a zone, so without it the stamp is parsed in the
# host's local time and the resulting epoch is skewed by the UTC offset — while
# `_reconcile_now` (date +%s) is true UTC, so `now - upd_epoch` would not cancel.
_reconcile_epoch_of() {
  local iso="$1"
  [ -n "$iso" ] || return 0
  TZ=UTC date -d "$iso" +%s 2>/dev/null && return 0
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  return 0
}

# Emit every live window's @claimed_issue value, one per line (blanks dropped).
# Outside tmux this prints nothing (no server to query). list-windows -a spans
# ALL sessions/windows on the server; -F '#{@claimed_issue}' yields the option
# (empty string for unset). The grep drops empties so only set markers remain.
reconcile_markers() {
  if [ -z "${TMUX:-}" ]; then
    return 0
  fi
  _reconcile_tmux list-windows -a -F '#{@claimed_issue}' 2>/dev/null |
    grep -v '^$' || true
}

# Extract the leading issue number from a marker display string. claim.sh stores
# markers as "#<n>" or "#<n> <short title>", so the number is the run of digits
# right after a leading '#'. Prints nothing if the marker has no leading "#<n>".
marker_issue_number() {
  printf '%s\n' "$1" | sed -n 's/^#\([0-9][0-9]*\).*/\1/p'
}

# Set membership helper: is issue $1 present in the newline list $2?
in_list() {
  printf '%s\n' "$2" | grep -x "$1" >/dev/null
}

# --- Lens 1 repair: terminality oracle (temperloop#748) ----------------------
# Is <number> PROVABLY terminal on GitHub — i.e. does its backing issue (or PR,
# since the two share one number namespace) read CLOSED or MERGED? Prints the
# upper-cased state, or nothing when it cannot be established. Routes through
# `_board_gh` so a test replays it offline with zero network, like every other
# GitHub read in this file. Single-item reads, NOT the Lens 2 bulk lists: the
# repair has at most ONE candidate (this window's own marker), so one targeted
# read is strictly cheaper than two whole-repo pages — and these are REST reads,
# never Projects-v2 GraphQL, so they cost nothing against the board budget.
#
# FAIL-SAFE BY CONSTRUCTION: any failure — a missing issue, an auth error, an
# unparseable payload — yields an empty string, which the caller treats as "not
# provably terminal" and therefore does NOT repair. A read failure can only ever
# make this path do less, never more.
#   _reconcile_issue_state <repo> <number>
_reconcile_issue_state() {
  local repo="$1" n="$2" json state=""
  json="$(_board_gh issue view "$n" -R "$repo" --json state 2>/dev/null || true)"
  if [ -n "$json" ]; then
    state="$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null || true)"
  fi
  if [ -z "$state" ]; then
    json="$(_board_gh pr view "$n" -R "$repo" --json state 2>/dev/null || true)"
    if [ -n "$json" ]; then
      state="$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null || true)"
    fi
  fi
  printf '%s' "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
}

# --- Lens 1 repair: the one safe marker repair (temperloop#748) --------------
# Clear THIS WINDOW's claim marker, and only when it is provably safe to do so.
# See the "Lens 1 repair" header section for the full rationale; the gates are:
#
#   gate 0 — a marker is actually set in THIS window (claim_marker_peek), and it
#            carries a leading "#<n>".
#   gate 1 — that #<n> is marker-without-board DRIFT: the board does NOT have it
#            In Progress stamped to this host. A live same-host claim is never
#            touched (that is the K#275 claim-until-Done case).
#   gate 2 — #<n> is PROVABLY TERMINAL on GitHub (CLOSED or MERGED). An OPEN
#            issue — or a state we could not read — is reported, never cleared.
#
# Only after all three does it call `claim_marker_clear` (release.sh's own
# primitive). The `board-without-marker` class never reaches here at all: this
# function starts from a marker that EXISTS, so a board claim with no marker has
# nothing for it to act on — it is structurally unreachable, not merely skipped.
#   _reconcile_marker_repair <host> <board-in-progress-tsv>
_reconcile_marker_repair() {
  local host="$1" board_ip_tsv="$2"
  local cur n row ip_host repo state prev

  echo "--fix (marker lens): repairing THIS window's marker only, provably-terminal claims only."
  echo "  (board-without-marker is never repaired — report-only by design, temperloop#719)"

  cur="$(claim_marker_peek)"
  if [ -z "$cur" ]; then
    echo "  nothing to repair: no claim marker is set in this window."
    echo "  A stale marker in ANOTHER window is cleared by running this from that window."
    return 0
  fi

  n="$(marker_issue_number "$cur")"
  if [ -z "$n" ]; then
    echo "  not repaired: this window's marker ('$cur') carries no leading '#<issue>'."
    return 0
  fi

  # gate 1 — must be marker-without-board drift, not a live same-host claim.
  row="$(printf '%s\n' "$board_ip_tsv" | awk -F'\t' -v n="$n" '$1==n {print; exit}')"
  if [ -n "$row" ]; then
    ip_host="$(printf '%s' "$row" | cut -f2)"
    if [ "$ip_host" = "$host" ]; then
      echo "  #$n — NOT repaired: it is In Progress on the board, stamped to this host '$host' (a live claim)."
      return 0
    fi
  fi

  # gate 2 — must be provably terminal on GitHub.
  repo="$(board_repo "$PROJECT_NUMBER")" || repo=""
  if [ -z "$repo" ]; then
    echo "  #$n — NOT repaired: could not resolve the repo for board $PROJECT_NUMBER to check its state." >&2
    return 0
  fi
  state="$(_reconcile_issue_state "$repo" "$n")"
  case "$state" in
    CLOSED|MERGED) ;;
    *)
      echo "  #$n — NOT repaired: marker is stale, but #$n is not provably terminal (state '${state:-unknown}')."
      return 0 ;;
  esac

  prev="$(claim_marker_clear)"
  if [ -n "$prev" ]; then
    echo "  ✓ cleared [$prev] — #$n is $state; status now shows 'No Issue Claimed'"
  else
    echo "  ✓ #$n is $state; no marker remained to clear (outside every multiplexer?)"
  fi
  return 0
}

# The whole report, wrapped so a test can source this file (defining its seam
# overrides AFTER board.sh is sourced) and drive it without the script running
# at import time. The execute-guard at the bottom calls this only when the file
# is run directly. All board/tmux access inside flows through the two seams.
reconcile_main() {
  # --- host identity (must match claim.sh) --------------------------------
  local HOST
  HOST="${SUBSET_HOST_LABEL:-$(hostname -s)}"

  # Resolve board state once (cached BOARD_ITEMS_JSON powers every read below).
  board_resolve "$PROJECT_NUMBER"

  local board_ip_tsv marker_numbers marker_without_board board_without_marker
  local m n row ip_host num title drift

  # --- board side: items In Progress, with their issue# and Host/Session host -
  # One JSON pass yields TSV rows "<issue#>\t<host-part>\t<title>" for every
  # item whose Status is the In-Progress option. host-part is the substring of
  # Host/Session before the first ':' ("" when unstamped). The item-list JSON
  # lowercases the first letter of free-text field names, so it is "host/Session".
  board_ip_tsv="$(
    printf '%s' "$BOARD_ITEMS_JSON" | jq -r --arg ip "$BOARD_OPT_INPROGRESS" '
      .items[]
      | select(.status == $ip)
      | [ (.content.number | tostring),
          ((.["host/Session"] // "") | split(":")[0]),
          (.content.title // "") ]
      | @tsv
    '
  )"

  # --- tmux side: issue numbers of live markers on this server ---------------
  # Dedupe so two windows holding the same marker count once.
  marker_numbers="$(
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      n="$(marker_issue_number "$m")"
      [ -n "$n" ] && printf '%s\n' "$n"
    done < <(reconcile_markers) | sort -u
  )"

  # --- direction 1: marker-without-board -------------------------------------
  # For each live marker number, drift if the board does NOT have it In Progress
  # stamped to THIS host. We classify the reason for a clearer report.
  marker_without_board=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    # Find this issue among the board's In-Progress rows (if any).
    row="$(printf '%s\n' "$board_ip_tsv" | awk -F'\t' -v n="$n" '$1==n {print; exit}')"
    if [ -z "$row" ]; then
      marker_without_board+="  #$n — marker set locally, but #$n is NOT In Progress on the board"$'\n'
      continue
    fi
    ip_host="$(printf '%s' "$row" | cut -f2)"
    if [ "$ip_host" != "$HOST" ]; then
      if [ -z "$ip_host" ]; then
        marker_without_board+="  #$n — In Progress on the board but UNSTAMPED (not this host '$HOST')"$'\n'
      else
        marker_without_board+="  #$n — In Progress on the board but stamped to '$ip_host', not this host '$HOST'"$'\n'
      fi
    fi
  done < <(printf '%s\n' "$marker_numbers")

  # --- direction 2: board-without-marker -------------------------------------
  # For each In-Progress item stamped to THIS host, drift if no live marker holds
  # its number.
  board_without_marker=""
  while IFS=$'\t' read -r num ip_host title; do
    [ -n "$num" ] || continue
    [ "$ip_host" = "$HOST" ] || continue
    if ! in_list "$num" "$marker_numbers"; then
      board_without_marker+="  #$num — In Progress on the board (this host) but NO live tmux marker — $title"$'\n'
    fi
  done < <(printf '%s\n' "$board_ip_tsv")

  # --- report ----------------------------------------------------------------
  echo "Claim-marker reconcile — host '$HOST', board project $PROJECT_NUMBER"
  if [ -z "${TMUX:-}" ]; then
    echo "(not inside tmux: no local markers to read; only board→marker drift is meaningful)"
  fi
  echo

  drift=0

  if [ -n "$marker_without_board" ]; then
    drift=1
    echo "marker-without-board (stale local marker):"
    printf '%s' "$marker_without_board"
    if [ "$FIX" != 1 ]; then
      echo "  (pass --fix to clear THIS window's marker when its issue is closed/merged)"
    fi
    echo
  fi

  if [ -n "$board_without_marker" ]; then
    drift=1
    echo "board-without-marker (claimed on board, no local marker — REPORT-ONLY, never repaired):"
    printf '%s' "$board_without_marker"
    echo
  fi

  if [ "$drift" -eq 0 ]; then
    echo "In sync: every local marker matches a board In-Progress claim for this host, and vice versa."
  fi

  # OPT-IN repair (temperloop#748). Without --fix this lens has mutated nothing
  # above and returns here having only reported — the dry-run contract.
  if [ "$FIX" = 1 ]; then
    echo
    _reconcile_marker_repair "$HOST" "$board_ip_tsv"
  fi

  return 0
}

# --- Lens 2: status drift (board Status vs. GitHub reality) -------------------
# Wrapped like reconcile_main so a test can source this file, override _board_gh
# (board reads, the two issue/pr list reads, and the item-edit writes the --fix
# path issues), set $FIX, and drive it offline. Always exits 0; the report is the
# output. With FIX=1 it applies ONLY the terminal→Done repair.
status_reconcile_main() {
  board_resolve "$PROJECT_NUMBER"
  local repo issues_json prs_json state_map rows HOST
  repo="$(board_repo "$PROJECT_NUMBER")"
  # Host identity must match claim.sh's stamp host-part (GH #85 liveness check).
  HOST="${SUBSET_HOST_LABEL:-$(hostname -s)}"

  # Bulk-read issue + PR state in two flat-cost REST list calls (the item-list
  # JSON has no state field). gh reports state as OPEN/CLOSED for issues and
  # OPEN/CLOSED/MERGED for PRs; numbers share one namespace, so merge into one
  # {"<number>":"<STATE>"} map. Route through _board_gh so a test can stub them.
  # updatedAt rides along on the SAME two reads (no extra call) — it ages foreign
  # claims for the GH #152 escalation. Two maps from one reduce: state + updatedAt.
  #
  # This same read ALSO feeds the closed-issue tail scan below (temperloop#1410),
  # which needs each issue's labels + title — so it asks for two more fields
  # rather than paying a second list call. Every registered board runs the
  # issues-only backend (temperloop#524's 2026-08-04 addendum), so this is no
  # longer conditional on backend.
  local issue_fields="number,state,updatedAt,labels,title"
  issues_json="$(_board_gh issue list -R "$repo" --state all --limit "$STATE_LIMIT" --json "$issue_fields")"
  prs_json="$(_board_gh pr list -R "$repo" --state all --limit "$STATE_LIMIT" --json number,state,updatedAt)"
  state_map="$(jq -n --argjson i "$issues_json" --argjson p "$prs_json" '
    reduce (($i[]), ($p[])) as $x ({}; .[$x.number | tostring] = $x.state)')"
  local updated_map
  updated_map="$(jq -n --argjson i "$issues_json" --argjson p "$prs_json" '
    reduce (($i[]), ($p[])) as $x ({}; .[$x.number | tostring] = ($x.updatedAt // ""))')"

  # Warn (don't silently truncate) if either list hit the fetch cap.
  if [ "$(printf '%s' "$issues_json" | jq 'length')" -ge "$STATE_LIMIT" ] ||
     [ "$(printf '%s' "$prs_json" | jq 'length')" -ge "$STATE_LIMIT" ]; then
    echo "WARNING: issue/PR list hit the ${STATE_LIMIT}-item cap — state for older items may be unread." >&2
  fi

  # Classify every real (non-draft) board item into one drift class, in one jq
  # pass. Emits TSV "<class>\t<number>\t<status>\t<state>\t<title>\t<stamp>";
  # class ∈ {terminal, orphan, claimed, unknown}; ok items emit nothing. Priority:
  # terminal (a closed item should be Done regardless of its stamp) > orphan
  # (In-Progress, EMPTY stamp — GH #103) > claimed (In-Progress, NON-empty stamp;
  # liveness is decided in the bash loop below, which jq can't do — GH #85).
  # <stamp> is the full Host/Session value, only meaningful for `claimed` rows
  # (empty for the rest — a harmless trailing TSV field).
  rows="$(
    printf '%s' "$BOARD_ITEMS_JSON" | jq -r \
      --argjson states "$state_map" --argjson updated "$updated_map" \
      --arg doneopt "$BOARD_OPT_DONE" --arg ip "$BOARD_OPT_INPROGRESS" '
      .items[]
      | select(.content.number != null)
      | (.content.number) as $num
      | (.status // "") as $st
      | (.["host/Session"] // "") as $stamp
      | ($stamp | split(":")[0] // "") as $hp
      | (.content.title // "") as $title
      | ($states[$num | tostring]) as $state
      | ($updated[$num | tostring] // "") as $upd
      # stout is the status rendered for OUTPUT, never empty: a no-status item must
      # not emit a bare empty middle TSV field, which the reader collapses (tab is
      # IFS-whitespace) and so shifts the downstream columns. The trailing $upd
      # column is only meaningful for `claimed` rows (foreign-age check); it tails
      # harmlessly on the rest, just like $stamp.
      | (if $st == "" then "(none)" else $st end) as $stout
      | if $state == null then ["unknown", ($num|tostring), $stout, "?", $title, "", ""]
        elif ($state == "CLOSED" or $state == "MERGED") and ($st != $doneopt)
          then ["terminal", ($num|tostring), $stout, $state, $title, "", ""]
        elif ($st == $ip) and ($hp == "") then ["orphan", ($num|tostring), $stout, $state, $title, "", ""]
        elif ($st == $ip) then ["claimed", ($num|tostring), $stout, $state, $title, $stamp, $upd]
        else empty end
      | @tsv'
  )"

  local terminal orphan stale foreign foreign_stale unknown class num st state title stamp upd fixed=0
  local shost ssess upd_epoch now age
  terminal=""; orphan=""; stale=""; foreign=""; foreign_stale=""; unknown=""
  now="$(_reconcile_now)"
  while IFS=$'\t' read -r class num st state title stamp upd; do
    [ -n "$class" ] || continue
    case "$class" in
      terminal) terminal+="  #$num — backing $state but board status '${st:-(none)}' — should be Done: $title"$'\n' ;;
      orphan)   orphan+="  #$num — In Progress with no Host/Session owner (orphaned claim) — $title"$'\n' ;;
      unknown)  unknown+="  #$num — board status '${st:-(none)}' but #$num is in neither the issue nor PR list: $title"$'\n' ;;
      claimed)
        # In Progress with a real owner stamp `<host>:<sess>`. A claim stamped to
        # THIS host whose session is dead is a stranded claim (GH #85); a claim on
        # ANOTHER host can't be liveness-checked from here, so it is report-only.
        shost="${stamp%%:*}"; ssess="${stamp#*:}"
        if [ "$shost" = "$HOST" ]; then
          if ! _reconcile_session_live "$ssess"; then
            stale+="  #$num — stamped '$stamp' but that session is not live on this host '$HOST' — $title"$'\n'
          fi
        else
          # Foreign: unverifiable here. Escalate if its backing issue/PR has had no
          # activity for > the foreign cutoff — likely a host that will never drain
          # again (GH #152). Unparseable/missing updatedAt → fail safe to plain foreign.
          upd_epoch="$(_reconcile_epoch_of "$upd")"
          if [ -n "$upd_epoch" ] && [ "$((now - upd_epoch))" -gt "$RECONCILE_FOREIGN_STALE_AFTER_SECS" ]; then
            age=$(( (now - upd_epoch) / 86400 ))
            foreign_stale+="  #$num — stamped '$stamp' (host '$shost'), no activity for ${age}d — $title"$'\n'
          else
            foreign+="  #$num — stamped '$stamp' (host '$shost' ≠ this host '$HOST') — $title"$'\n'
          fi
        fi
        ;;
    esac
  done < <(printf '%s\n' "$rows")

  # --- the CLOSED-ISSUE TAIL (temperloop#1410) ------------------------------
  # Every class above starts from a board item. On the issues-only backend the
  # whole-board read is the OPEN issue set, so a closed issue still wearing a
  # `fnd:status:*` label or a `fnd:host/session:*` claim stamp is invisible to it
  # — the blindness this scan closes. See the "Lens 2, the CLOSED-ISSUE TAIL"
  # header section for the full rationale. Every registered board runs the
  # issues-only backend (temperloop#524's 2026-08-04 addendum), so this scan is
  # unconditional now. Both label prefixes are DERIVED from the same helpers
  # the write path uses (never hardcoded), so they stay in lockstep with the
  # `fnd:` vocabulary — exactly as Lens 3's scan 2b does.
  local residual_status="" stranded_stamp=""
  local st_prefix hs_prefix closed_rows cls cnum clab ctitle
  st_prefix="$(_board_issues_label_prefix "$BOARD_FIELD_STATUS")"
  hs_prefix="$(_board_issues_label_prefix "$BOARD_FIELD_HOSTSESSION")"
  # Reuses $issues_json — the SAME `--state all` read made above, no extra gh
  # call. Emits TSV "<class>\t<number>\t<label>\t<title>"; a closed issue
  # wearing both kinds of label emits one row per label, like Lens 3.
  closed_rows="$(
    printf '%s' "$issues_json" | jq -r --arg sp "$st_prefix" --arg hp "$hs_prefix" '
      .[]
      | select(((.state // "") | ascii_downcase) == "closed")
      | .number as $n
      | (.title // "") as $t
      | ((.labels // []) | map(.name)) as $ls
      | ( ($ls[] | select(startswith($sp)) | ["residual", ($n|tostring), ., $t]),
          ($ls[] | select(startswith($hp)) | ["stranded", ($n|tostring), ., $t]) )
      | @tsv'
  )"
  while IFS=$'\t' read -r cls cnum clab ctitle; do
    [ -n "$cls" ] || continue
    case "$cls" in
      residual) residual_status+="  #$cnum — CLOSED but still labeled '$clab' (Done here is 'closed + no status label') — $ctitle"$'\n' ;;
      stranded) stranded_stamp+="  #$cnum — CLOSED but still stamped '$clab' (reads as a live, unreleasable claim) — $ctitle"$'\n' ;;
    esac
  done < <(printf '%s\n' "$closed_rows")

  echo "Status reconcile — board project $PROJECT_NUMBER ($repo)"
  echo

  local drift=0
  if [ -n "$terminal" ]; then
    drift=1
    echo "terminal-but-not-Done (work complete, board not):"
    printf '%s' "$terminal"
    if [ "$FIX" = 1 ]; then
      echo "  → --fix: moving these to Done…"
      # 5-field read of a 7-field row: only class/num are used here; a terminal
      # row's two trailing (empty) columns — stamp + updatedAt — harmlessly tail
      # into $title, which this loop ignores. Any future field that terminal rows
      # POPULATE (rather than emit empty) would need this reader widened to match.
      while IFS=$'\t' read -r class num st state title; do
        [ "$class" = terminal ] || continue
        if board_set_status "$(board_item_id "$num")" "$BOARD_OPT_DONE"; then
          echo "    ✓ #$num → Done"; fixed=$((fixed + 1))
        else
          echo "    ✗ #$num — could not set Done" >&2
        fi
      done < <(printf '%s\n' "$rows")
      echo "  fixed $fixed item(s)."
    fi
    echo
  fi

  # Class (k) — the issues-only analogue of terminal-but-not-Done, printed right
  # after it. REPORT-ONLY: the repair lives exactly once, in Lens 3.
  if [ -n "$residual_status" ]; then
    drift=1
    echo "residual status labels on closed issues (work complete, tracker label not stripped):"
    printf '%s' "$residual_status"
    echo "  (repair: reconcile.sh --board $PROJECT_NUMBER --labels --apply)"
    echo
  fi

  if [ -n "$orphan" ]; then
    drift=1
    echo "orphaned In-Progress (report-only — park by hand: release.sh / re-claim):"
    printf '%s' "$orphan"
    echo
  fi

  if [ -n "$stale" ]; then
    drift=1
    echo "stale claims (In Progress, stamped to a dead same-host session — park by hand):"
    printf '%s' "$stale"
    echo
  fi

  if [ -n "$foreign" ]; then
    drift=1
    echo "foreign claims (In Progress on another host — verify there, not released from here):"
    printf '%s' "$foreign"
    echo
  fi

  if [ -n "$foreign_stale" ]; then
    drift=1
    echo "foreign claims (STALE — escalate: owning host may be gone; verify there, then release.sh by hand):"
    printf '%s' "$foreign_stale"
    echo
  fi

  # Class (l) — the closed-issue half of the claim-rot picture, printed with the
  # other claim buckets. Same population Lens 3 class (j) reports, so --status
  # and --labels can no longer disagree about whether the board is clean.
  if [ -n "$stranded_stamp" ]; then
    drift=1
    echo "stranded claim stamps on closed issues (claim lock that can never be released):"
    printf '%s' "$stranded_stamp"
    echo "  (repair: reconcile.sh --board $PROJECT_NUMBER --labels --apply)"
    echo
  fi

  if [ -n "$unknown" ]; then
    drift=1
    echo "unresolved (state not found — cross-repo or past the fetch cap):"
    printf '%s' "$unknown"
    echo
  fi

  if [ "$drift" -eq 0 ]; then
    echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."
  fi
  return 0
}

# --- Lens 3: label hygiene (board LABEL drift on the issues-only backend) ----
# Best-effort append of an `ask-at-checkin` pending-decision entry recording an
# UNATTENDED label-hygiene apply (`claude/CLAUDE.md` § Unattended
# pending-decisions surface). Routes through workflows/scripts/lib/
# knowledge_store.sh's `ks_read`/`ks_append` — the SCRIPT-plane seam (portable
# to a stranger's kernel-only install with no Obsidian vault), never the
# agent-plane MCP tools. A missing knowledge_store.sh, an unavailable store, or
# a failed ks_append must NEVER fail the sweep itself — every failure path
# below degrades to a stderr notice and returns 0. Implements the same
# append-target resolution rule named by claude/commands/check-in.md's "Path
# fallback convention" section: pin the append to whichever of the new
# (`Pipeline/…`) / legacy (`Context/pipeline - …`) paths already exists,
# preferring the new path when both do, and create at the legacy path when
# neither exists yet.
#   _label_reconcile_append_pending_decision <board#> <repo> <deleted> <stripped> [<backfilled>] [<cleared>] [<parked>]
_label_reconcile_append_pending_decision() {
  local board="$1" repo="$2" deleted="$3" stripped="$4" backfilled="${5:-0}" cleared="${6:-0}" parked="${7:-0}"
  local ks_lib doc new_doc legacy_doc ts host decision_extra taken_extra

  ks_lib="$SCRIPT_DIR/../lib/knowledge_store.sh"
  if [ ! -f "$ks_lib" ]; then
    echo "reconcile.sh: label hygiene — knowledge_store.sh not found at $ks_lib; skipping pending-decision append" >&2
    return 0
  fi
  # shellcheck disable=SC1090,SC1091  # optional, guarded above — a synced consumer tree may not carry the lib
  source "$ks_lib" 2>/dev/null || {
    echo "reconcile.sh: label hygiene — failed to source knowledge_store.sh; skipping pending-decision append" >&2
    return 0
  }
  if ! declare -F ks_append >/dev/null 2>&1; then
    echo "reconcile.sh: label hygiene — ks_append unavailable after sourcing knowledge_store.sh; skipping pending-decision append" >&2
    return 0
  fi

  new_doc="Pipeline/pending decisions.md"
  legacy_doc="Context/pipeline - pending decisions.md"
  if ks_read "$new_doc" >/dev/null 2>&1; then
    doc="$new_doc"
  elif ks_read "$legacy_doc" >/dev/null 2>&1; then
    doc="$legacy_doc"
  else
    doc="$legacy_doc"   # neither exists yet — create at the legacy path
  fi

  # Human-facing heading stamp on the pending-decisions review surface renders in
  # the operator's display timezone (kernel doc § Communication conventions); %Z
  # names the zone explicitly so a reader never has to guess. Belt-and-suspenders
  # default per § Named-setting convention — this board script is vendored
  # into consumer repos that may not carry build.config.sh. The reconcile epoch
  # math (_reconcile_now) stays UTC — absolute instants, unaffected.
  ts="$(TZ="${DISPLAY_TZ:-America/Los_Angeles}" date '+%Y-%m-%d %H:%M %Z')"
  host="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
  # Only name the claim-stamp (temperloop#744) / parked-claim-stamp
  # (temperloop#979) / backfill (temperloop#376) dimensions when each actually
  # acted, so a sweep that deleted/stripped but cleared and backfilled nothing
  # keeps its prior wording verbatim. Same cleared → parked → backfilled order
  # as the on-screen applied: summary.
  decision_extra=""; taken_extra=""
  if [ "${cleared:-0}" -gt 0 ]; then
    # shellcheck disable=SC2016  # literal markdown span, not expansion
    decision_extra=' and clear stranded `fnd:host/session:*` claim stamps from closed issues'
    taken_extra="$(printf ', cleared %s claim stamp(s)' "$cleared")"
  fi
  if [ "${parked:-0}" -gt 0 ]; then
    # shellcheck disable=SC2016  # literal markdown span, not expansion
    decision_extra+=' and clear parked `fnd:host/session:*` claim stamps from open issues that are not In Progress'
    taken_extra+="$(printf ', cleared %s parked claim stamp(s)' "$parked")"
  fi
  if [ "${backfilled:-0}" -gt 0 ]; then
    # shellcheck disable=SC2016  # literal markdown span, not expansion
    decision_extra+=' and backfill `fnd:status:backlog` on unstatused open issues'
    taken_extra+="$(printf ', backfilled %s status label(s)' "$backfilled")"
  fi
  if {
    printf '### %s · label hygiene sweep · %s:board%s\n' "$ts" "$host" "$board"
    # shellcheck disable=SC2016  # backticks below are literal markdown spans, not expansion
    printf -- '- **Decision:** delete orphaned `fnd:host/session:*` repo labels (zero open-issue attachments) and strip `fnd:status:*` from closed issues%s on board %s (%s)\n' "$decision_extra" "$board" "$repo"
    printf -- '- **Default taken:** applied — deleted %s label(s), stripped %s status label(s)%s\n' "$deleted" "$stripped" "$taken_extra"
    printf -- '- **Disposition:** auto-taken (unattended; no live operator)\n'
    printf -- '- **Status:** open\n'
  } | ks_append "$doc" 2>/dev/null; then
    return 0
  fi
  echo "reconcile.sh: label hygiene — ks_append to $doc failed; pending-decision entry not recorded" >&2
  return 0
}

# Strip a set of `<issue#>\t<fnd-label>` rows — the ONE implementation all THREE
# Lens 3 strip classes share: (h) stale `fnd:status:*` and (j) stranded
# `fnd:host/session:*` claim stamps, both on CLOSED issues (temperloop#744), and
# (m) PARKED `fnd:host/session:*` claim stamps on OPEN, not-In-Progress issues
# (temperloop#979). Each row is RE-CHECKED immediately before its write (a fresh
# single-issue `api` read, not the scan's bulk snapshot), so a status write, a
# re-claim, a REOPEN, or a CLOSE landing in the scan→apply gap is never undone —
# the issue must still be in <want-state> AND still carry that exact label AND
# (when <forbid-label> is given) still NOT carry that label. Only the named
# label is removed; the issue's other labels (fnd: or not) are never read for
# candidacy or touched.
#
# <want-state> defaults to "closed" and <forbid-label> to empty, so the two
# pre-existing (h)/(j) call sites are byte-identical to before — including their
# "skip (no longer closed+labeled)" notice, which the open arm renames rather
# than reuses so a reader can tell WHICH re-check refused.
#
# Publishes the applied count in $_LABEL_STRIP_APPLIED rather than returning it,
# because the loop must run in the CALLER's shell (its `echo`s are part of the
# report, and a command-substitution subshell would swallow the counter anyway).
#   _label_reconcile_strip_rows <owner/repo> <rows> [<want-state>] [<forbid-label>]
_LABEL_STRIP_APPLIED=0
_label_reconcile_strip_rows() {
  local repo="$1" rows="$2" want_state="${3:-closed}" forbid_label="${4:-}"
  local n l issue_json state has_label has_forbid skip_why
  _LABEL_STRIP_APPLIED=0
  [ -n "$rows" ] || return 0
  if [ "$want_state" = "closed" ]; then
    skip_why="skip (no longer closed+labeled)"
  else
    skip_why="skip (no longer open+parked+labeled)"
  fi
  while IFS=$'\t' read -r n l; do
    [ -n "$n" ] || continue
    issue_json="$(_board_gh api "repos/$repo/issues/$n" 2>/dev/null)"
    state="$(printf '%s' "$issue_json" | jq -r '.state // "open"')"
    has_label="$(printf '%s' "$issue_json" | jq -r --arg l "$l" '([.labels[]?.name] | index($l)) != null')"
    has_forbid=false
    if [ -n "$forbid_label" ]; then
      has_forbid="$(printf '%s' "$issue_json" | jq -r --arg l "$forbid_label" '([.labels[]?.name] | index($l)) != null')"
    fi
    if [ "$state" != "$want_state" ] || [ "$has_label" != "true" ] || [ "$has_forbid" = "true" ]; then
      echo "  $skip_why: #$n $l"
      continue
    fi
    if _board_gh issue edit "$n" -R "$repo" --remove-label "$l" >/dev/null 2>&1; then
      echo "  stripped: #$n $l"
      _LABEL_STRIP_APPLIED=$((_LABEL_STRIP_APPLIED + 1))
    else
      echo "  FAILED to strip: #$n $l" >&2
    fi
  done <<<"$rows"
  return 0
}

# The Lens 3 report+apply, wrapped like reconcile_main/status_reconcile_main so
# a test can source this file, override _board_gh, set $LABELS_APPLY/
# $LABELS_UNATTENDED, and drive it offline. Always exits 0.
label_reconcile_main() {
  local repo hs_labels_json hs_labels orphan_hs_labels closed_json strip_rows
  local label recheck_count deleted=0 stripped=0 cleared=0 backfilled=0 parked=0
  local n l issue_json state has_status
  local open_json unstatused_rows backlog_label
  local hs_prefix hs_strip_rows inprogress_label parked_stamp_rows

  # Every registered board runs the issues-only backend (fnd: labels only
  # exist there; temperloop#524's 2026-08-04 addendum), so this sweep is
  # unconditional now.
  repo="$(board_repo "$PROJECT_NUMBER")" || {
    echo "reconcile.sh: label hygiene — could not resolve repo for board $PROJECT_NUMBER" >&2
    return 0
  }
  # The canonical Backlog status label, derived (never hardcoded) from the SAME
  # helpers the write path uses (_board_issues_set_field) so it stays in lockstep
  # with the fnd: vocabulary — "fnd:status:backlog".
  backlog_label="$(_board_issues_label_prefix "$BOARD_FIELD_STATUS")$(_board_issues_slug "$BOARD_OPT_BACKLOG")"
  # The In-Progress status label, derived the same way (never hardcoded) — the
  # ONE thing that makes a claim stamp on an open issue legitimate (class m).
  inprogress_label="$(_board_issues_label_prefix "$BOARD_FIELD_STATUS")$(_board_issues_slug "$BOARD_OPT_INPROGRESS")"

  # --- scan 1: orphaned fnd:host/session:* repo labels ------------------------
  # Every repo label carrying the prefix, filtered LOCALLY (jq startswith) to
  # the exact prefix rather than relying on `gh label list --search`'s fuzzy
  # text match — never lists a non-fnd: label as a candidate.
  hs_labels_json="$(_board_gh label list -R "$repo" --limit "$LABEL_LIMIT" --json name 2>/dev/null)" || hs_labels_json="[]"
  [ -n "$hs_labels_json" ] || hs_labels_json="[]"
  if [ "$(printf '%s' "$hs_labels_json" | jq 'length')" -ge "$LABEL_LIMIT" ]; then
    echo "WARNING: repo label list hit the ${LABEL_LIMIT}-item cap — some fnd:host/session:* labels may be unread." >&2
  fi
  hs_labels="$(printf '%s' "$hs_labels_json" | jq -r '.[].name | select(startswith("fnd:host/session:"))')"

  # A label is an orphan candidate iff it is attached to ZERO open issues. One
  # `issue list --label … --state open --limit 1` read per candidate label
  # (bounded by the repo's real fnd:host/session:* label count — every claim
  # ever made, not every claim currently live).
  orphan_hs_labels=""
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    recheck_count="$(_board_gh issue list -R "$repo" --label "$label" --state open --limit 1 --json number 2>/dev/null | jq 'length')"
    [ "${recheck_count:-0}" -eq 0 ] && orphan_hs_labels+="$label"$'\n'
  done < <(printf '%s\n' "$hs_labels")

  # --- scan 2: stale fnd:status:* labels on CLOSED issues ----------------------
  # One bulk read of every closed issue's labels; filter LOCALLY to fnd:status:
  # rows so a closed issue's other labels are never touched or listed.
  closed_json="$(_board_gh issue list -R "$repo" --state closed --limit "$LABEL_LIMIT" --json number,labels 2>/dev/null)" || closed_json="[]"
  [ -n "$closed_json" ] || closed_json="[]"
  if [ "$(printf '%s' "$closed_json" | jq 'length')" -ge "$LABEL_LIMIT" ]; then
    echo "WARNING: closed-issue list hit the ${LABEL_LIMIT}-item cap — some stale fnd:status:* labels may be unread." >&2
  fi
  strip_rows="$(
    printf '%s' "$closed_json" | jq -r '
      .[] | .number as $n
      | (.labels[]? | .name | select(startswith("fnd:status:"))) as $l
      | [ ($n|tostring), $l ] | @tsv
    '
  )"

  # --- scan 2b: stranded fnd:host/session:* stamps on CLOSED issues (#744) -----
  # Class (j) — see this file's Lens 3 header. Reuses scan 2's SAME bulk read
  # (zero extra gh calls): a closed issue is the whole candidate population for
  # both classes, they differ only in which label prefix is stranded. The prefix
  # is DERIVED from the same helper the write path uses, never hardcoded, so it
  # stays in lockstep with the fnd: vocabulary — "fnd:host/session:".
  hs_prefix="$(_board_issues_label_prefix "$BOARD_FIELD_HOSTSESSION")"
  hs_strip_rows="$(
    printf '%s' "$closed_json" | jq -r --arg p "$hs_prefix" '
      .[] | .number as $n
      | (.labels[]? | .name | select(startswith($p))) as $l
      | [ ($n|tostring), $l ] | @tsv
    '
  )"

  # --- scan 3: OPEN issues carrying NO fnd:status:* label (temperloop#376) ------
  # One bulk read of every OPEN issue's labels; filter LOCALLY to those with zero
  # fnd:status:* labels — the class /triage's Backlog intake silently skips (an
  # unstatused issue reads as .status="" and Adapter A keeps only .status==Backlog).
  # Same flat-cost, non-Projects-GraphQL REST read shape as scan 2.
  open_json="$(_board_gh issue list -R "$repo" --state open --limit "$LABEL_LIMIT" --json number,labels 2>/dev/null)" || open_json="[]"
  [ -n "$open_json" ] || open_json="[]"
  if [ "$(printf '%s' "$open_json" | jq 'length')" -ge "$LABEL_LIMIT" ]; then
    echo "WARNING: open-issue list hit the ${LABEL_LIMIT}-item cap — some unstatused open issues may be unread." >&2
  fi
  unstatused_rows="$(
    printf '%s' "$open_json" | jq -r '
      .[]
      | select(([ .labels[]?.name | select(startswith("fnd:status:")) ] | length) == 0)
      | (.number|tostring)
    '
  )"

  # --- scan 3b: PARKED fnd:host/session:* stamps on OPEN issues (#979) ---------
  # Class (m) — see this file's Lens 3 header. Reuses scan 3's SAME bulk read
  # (zero extra gh calls): the open-issue set is the whole candidate population,
  # narrowed to those carrying a claim stamp while NOT In Progress. Both the
  # stamp prefix and the in-progress label are DERIVED from the same helpers the
  # write path uses (computed above), never hardcoded.
  parked_stamp_rows="$(
    printf '%s' "$open_json" | jq -r --arg p "$hs_prefix" --arg ip "$inprogress_label" '
      .[]
      | select(([ .labels[]?.name | select(. == $ip) ] | length) == 0)
      | .number as $n
      | (.labels[]? | .name | select(startswith($p))) as $l
      | [ ($n|tostring), $l ] | @tsv
    '
  )"

  # --- report -------------------------------------------------------------
  echo "Board label hygiene — board $PROJECT_NUMBER ($repo)"
  echo

  local drift=0
  if [ -n "$orphan_hs_labels" ]; then
    drift=1
    echo "orphaned host/session labels (attached to zero open issues):"
    printf '%s\n' "$orphan_hs_labels" | grep -v '^$' | sed 's/^/  /'
    echo
  fi
  if [ -n "$strip_rows" ]; then
    drift=1
    echo "stale status labels on closed issues:"
    while IFS=$'\t' read -r n l; do
      [ -n "$n" ] || continue
      echo "  #$n — $l"
    done <<<"$strip_rows"
    echo
  fi
  if [ -n "$hs_strip_rows" ]; then
    drift=1
    echo "stranded claim stamps on closed issues (read as still-claimed):"
    while IFS=$'\t' read -r n l; do
      [ -n "$n" ] || continue
      echo "  #$n — $l"
    done <<<"$hs_strip_rows"
    echo
  fi
  if [ -n "$parked_stamp_rows" ]; then
    drift=1
    echo "parked claim stamps on open issues (not In Progress — read as claimed by a session that is gone):"
    while IFS=$'\t' read -r n l; do
      [ -n "$n" ] || continue
      echo "  #$n — $l"
    done <<<"$parked_stamp_rows"
    echo
  fi
  if [ -n "$unstatused_rows" ]; then
    drift=1
    echo "unstatused open issues (no fnd:status:* label — invisible to /triage Backlog intake):"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      echo "  #$n — no fnd:status:* label; backfill target: $backlog_label"
    done <<<"$unstatused_rows"
    echo
  fi
  if [ "$drift" -eq 0 ]; then
    echo "In sync: no orphaned host/session labels, no stale status labels or stranded claim stamps on closed issues, no parked claim stamps on open issues, no unstatused open issues."
    return 0
  fi

  if [ "$LABELS_UNATTENDED" = 1 ]; then
    LABELS_APPLY=1
  fi

  if [ "$LABELS_APPLY" != 1 ]; then
    echo "(dry-run — no writes; pass --apply, or --unattended, to delete/strip these)"
    return 0
  fi

  echo "--apply: deleting/stripping…"

  # Delete each orphan label — RE-CHECKED immediately before the delete call
  # (a fresh, single-label `issue list` read, not the scan-1 snapshot above),
  # so a claim landing in the scan→apply gap is never destroyed.
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    recheck_count="$(_board_gh issue list -R "$repo" --label "$label" --state open --limit 1 --json number 2>/dev/null | jq 'length')"
    if [ "${recheck_count:-0}" -ne 0 ]; then
      echo "  skip (now attached to an open issue): $label"
      continue
    fi
    if _board_gh label delete "$label" -R "$repo" --yes >/dev/null 2>&1; then
      echo "  deleted: $label"
      deleted=$((deleted + 1))
    else
      echo "  FAILED to delete: $label" >&2
    fi
  done <<<"$orphan_hs_labels"

  # Strip each stale status label (class h), then each stranded claim stamp on a
  # closed issue (class j), then each PARKED claim stamp on an open, not-In-
  # Progress issue (class m, temperloop#979) — one shared implementation, see
  # _label_reconcile_strip_rows. The class-m call passes the open state and the
  # in-progress label as the re-check's forbidden label, so a stamp that became
  # a LIVE claim in the scan→apply gap is never erased.
  _label_reconcile_strip_rows "$repo" "$strip_rows"
  stripped="$_LABEL_STRIP_APPLIED"
  _label_reconcile_strip_rows "$repo" "$hs_strip_rows"
  cleared="$_LABEL_STRIP_APPLIED"
  _label_reconcile_strip_rows "$repo" "$parked_stamp_rows" open "$inprogress_label"
  parked="$_LABEL_STRIP_APPLIED"

  # Backfill fnd:status:backlog on each unstatused open issue — RE-CHECKED
  # immediately before the write (a fresh single-issue `api` read, not the
  # scan-3 bulk snapshot), so a status write OR a close that landed in the
  # scan→apply gap is never clobbered: an issue that gained a status label, or
  # was closed, in the gap is skipped. Ensure the label object exists first
  # (idempotent, memoized), same as the write path.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    issue_json="$(_board_gh api "repos/$repo/issues/$n" 2>/dev/null)"
    state="$(printf '%s' "$issue_json" | jq -r '.state // "open"')"
    has_status="$(printf '%s' "$issue_json" | jq -r '(([.labels[]?.name | select(startswith("fnd:status:"))] | length) > 0)')"
    if [ "$state" != "open" ] || [ "$has_status" = "true" ]; then
      echo "  skip (no longer open+unstatused): #$n"
      continue
    fi
    _board_issues_ensure_label "$repo" "$backlog_label" || true
    if _board_gh issue edit "$n" -R "$repo" --add-label "$backlog_label" >/dev/null 2>&1; then
      echo "  backfilled: #$n $backlog_label"
      backfilled=$((backfilled + 1))
    else
      echo "  FAILED to backfill: #$n $backlog_label" >&2
    fi
  done <<<"$unstatused_rows"

  echo
  # Only name the claim-stamp / parked-claim-stamp / backfill dimensions when
  # their scan actually found candidates, so a sweep with nothing to clear or
  # backfill prints its prior byte-identical summary line.
  local applied_summary="applied: deleted $deleted label(s), stripped $stripped status label(s)"
  [ -n "$hs_strip_rows" ] && applied_summary+="$(printf ', cleared %s claim stamp(s)' "$cleared")"
  [ -n "$parked_stamp_rows" ] && applied_summary+="$(printf ', cleared %s parked claim stamp(s)' "$parked")"
  [ -n "$unstatused_rows" ] && applied_summary+="$(printf ', backfilled %s status label(s)' "$backfilled")"
  echo "$applied_summary."

  if [ "$LABELS_UNATTENDED" = 1 ] && { [ "$deleted" -gt 0 ] || [ "$stripped" -gt 0 ] || [ "$cleared" -gt 0 ] || [ "$parked" -gt 0 ] || [ "$backfilled" -gt 0 ]; }; then
    _label_reconcile_append_pending_decision "$PROJECT_NUMBER" "$repo" "$deleted" "$stripped" "$backfilled" "$cleared" "$parked"
  fi
  return 0
}

# Execute-guard: run a report only when this file is RUN, not SOURCED. When
# sourced (BASH_SOURCE[0] != $0), a test sets $PROJECT_NUMBER / $FIX /
# $LABELS_APPLY / $LABELS_UNATTENDED, defines its _board_gh / _reconcile_tmux
# overrides, and calls reconcile_main / status_reconcile_main /
# label_reconcile_main itself — keeping these defaults untouched.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  MODE=markers
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)       PROJECT_NUMBER="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
      --status)      MODE=status; shift ;;
      --fix)         FIX=1; shift ;;
      --labels)      MODE=labels; shift ;;
      --apply)       LABELS_APPLY=1; shift ;;
      --unattended)  LABELS_UNATTENDED=1; shift ;;
      *) echo "usage: reconcile.sh [--board 3|4] [--fix | --status [--fix] | --labels [--apply|--unattended]]" >&2; exit 2 ;;
    esac
  done
  # --fix now applies to BOTH repair-bearing lenses — the default marker lens
  # (this window's provably-terminal stale marker, temperloop#748) and --status
  # (terminal→Done). It is still meaningless on --labels, whose apply verb is
  # --apply/--unattended, so that combination stays a hard error rather than a
  # silently-ignored flag.
  if [ "$FIX" = 1 ] && [ "$MODE" = labels ]; then
    echo "reconcile.sh: --fix does not apply to --labels (use --apply or --unattended there)" >&2
    exit 2
  fi
  if { [ "$LABELS_APPLY" = 1 ] || [ "$LABELS_UNATTENDED" = 1 ]; } && [ "$MODE" != labels ]; then
    echo "reconcile.sh: --apply/--unattended require --labels (they drive the label-hygiene sweep)" >&2
    exit 2
  fi
  case "$MODE" in
    markers) reconcile_main ;;
    status)  status_reconcile_main ;;
    labels)  label_reconcile_main ;;
  esac
fi
