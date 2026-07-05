#!/usr/bin/env bash
#
# Surface board DRIFT. Two independent lenses, selected by flag:
#
#   reconcile.sh [--board N]            (default) MARKER drift — board In-Progress
#                                       vs. the local tmux @claimed_issue markers
#                                       for THIS host. Read-only.
#   reconcile.sh [--board N] --status   STATUS drift — board Status vs. GitHub
#                                       reality (closed/merged backing issues/PRs,
#                                       orphaned In-Progress). Read-only report.
#          ... --status --fix           also auto-applies the one SAFE repair
#                                       (terminal-but-not-Done → Done).
#
# ─── Lens 1: marker drift (default) ──────────────────────────────────────────
# scripts/claim.sh stamps BOTH the board (Status=In Progress +
# Host/Session=`<host>:<sess8>`) AND a per-window tmux marker (@claimed_issue).
# scripts/release.sh clears ONLY the marker and deliberately does NOT un-claim
# the board ("Park, don't abandon"). So the two can legitimately drift, and until
# now nothing surfaced that drift. This does — for the current host only.
# Background. scripts/claim.sh stamps BOTH the board (Status=In Progress +
# Host/Session=`<host>:<sess8>`) AND a per-window tmux marker (@claimed_issue).
# scripts/release.sh clears ONLY the marker and deliberately does NOT un-claim
# the board ("Park, don't abandon"). So the two can legitimately drift, and until
# now nothing surfaced that drift. This command does — for the current host only.
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
# Usage:
#   scripts/reconcile.sh                       # marker drift report; exits 0
#   scripts/reconcile.sh --board 4 --status    # status drift report; exits 0
#   scripts/reconcile.sh --board 4 --status --fix   # + apply terminal→Done
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
source "$SCRIPT_DIR/lib/board.sh"

# reconcile is the board↔marker CONSISTENCY check — its whole job is to surface
# drift, so it must read the board LIVE. Opt out of the default-ON cross-process
# read cache (GH #93) here; a ≤90s-stale page would report phantom drift (a claim
# made seconds ago not yet in the cached page). It does a single resolve per run,
# so it gains nothing from the cache anyway.
#
# THIS LINE IS THE LIVE-READ PIN — the whole contract rests on it. Every board
# read in this file goes through board.sh's board_resolve/board_item_list, which
# route through _board_cached_read; BOARD_CACHE_TTL=0 is the one master
# off-switch that forces those reads live regardless of what's sitting in
# BOARD_CACHE_DIR (see _board_cached_read's "MASTER off-switch" comment in
# lib/board.sh). A drift detector fed cached data is self-defeating, so this
# export must never be removed, conditioned, or shadowed by a later cache layer
# (e.g. a future local issue-cache store) that doesn't also respect it — if a
# future cache-dispatch seam is added ahead of _board_cached_read, it MUST be
# bypassed here too, not just this TTL. tests/test_reconcile.sh's "live-pin"
# case proves this behaviorally: it seeds a FRESH, wrong on-disk cache file and
# asserts reconcile still reports the LIVE (_board_gh) truth, not the cache.
export BOARD_CACHE_TTL=0

PROJECT_NUMBER=3
# --status --fix: apply the one safe repair (terminal→Done). Set by the
# execute-guard or by a sourcing test before it calls status_reconcile_main.
FIX=0
# Page size for the issue/PR state bulk-reads. A board larger than this would
# under-read; status_reconcile_main warns when a list hits the cap (no silent cap).
STATE_LIMIT=1000
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
  printf '%s\n' "$2" | grep -qx "$1"
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
    echo
  fi

  if [ -n "$board_without_marker" ]; then
    drift=1
    echo "board-without-marker (claimed on board, no local marker):"
    printf '%s' "$board_without_marker"
    echo
  fi

  if [ "$drift" -eq 0 ]; then
    echo "In sync: every local marker matches a board In-Progress claim for this host, and vice versa."
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
  issues_json="$(_board_gh issue list -R "$repo" --state all --limit "$STATE_LIMIT" --json number,state,updatedAt)"
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

# Execute-guard: run a report only when this file is RUN, not SOURCED. When
# sourced (BASH_SOURCE[0] != $0), a test sets $PROJECT_NUMBER / $FIX, defines its
# _board_gh / _reconcile_tmux overrides, and calls reconcile_main or
# status_reconcile_main itself — keeping these defaults untouched.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  MODE=markers
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)  PROJECT_NUMBER="${2:?--board needs a value}"; shift 2 ;;
      --status) MODE=status; shift ;;
      --fix)    FIX=1; shift ;;
      *) echo "usage: reconcile.sh [--board 3|4] [--status [--fix]]" >&2; exit 2 ;;
    esac
  done
  if [ "$FIX" = 1 ] && [ "$MODE" != status ]; then
    echo "reconcile.sh: --fix requires --status (it repairs status drift)" >&2
    exit 2
  fi
  case "$MODE" in
    markers) reconcile_main ;;
    status)  status_reconcile_main ;;
  esac
fi
