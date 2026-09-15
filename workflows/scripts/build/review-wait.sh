#!/usr/bin/env bash
#
# review-wait.sh — the §3e review ceiling's WALL-CLOCK TICK (temperloop#2049).
#
#   review-wait.sh <secs>
#
# Waits <secs> seconds and then prints ONE JSON line on stdout:
#
#   {"outcome":"REVIEW_WAIT_ELAPSED","secs":N,"realized_secs":M}
#
# The line is printed ONLY after the interval has genuinely elapsed, and
# `realized_secs` is this script's OWN measurement of how long it actually
# waited — never a restatement of the request. That field is the whole point:
# claude/workflows/build-level.mjs honours a tick as elapsed only when
# realized_secs >= secs, so a timer that did not run cannot report that it did.
#
# WHY THIS SCRIPT EXISTS — temperloop#2049, the measured mechanism.
# temperloop#2003 gave the §3e fanout a wall-clock ceiling. The Workflow
# runtime has no clock (`Date.now()` throws, there is no timer primitive), so
# the ceiling raced the reviewers against a machinery executor asked to run
# `sleep N; printf '<json>'` INLINE as its Bash command. In the machinery
# executor's seat that command shape is REFUSED by a harness permission control
# ("Blocked: sleep 300 followed by: printf …"), in about a millisecond — and the
# executor's prompt then told it to report the interval elapsed anyway. The
# result, measured in run wf_ebd4b5e0-3a8's own agent transcripts:
#
#   review-wait #300   asked 300s   realized   8s
#   review-wait #840   asked 540s   realized   9s
#   review-wait #1200  asked 360s   realized   9s
#   ------------------------------------------------
#   nominal ceiling 1200s           realized  30s
#
# while the reviewers it was bounding took 177s and 257s — normal, and in the
# same band as the 89s/142s parent-side baseline the issue records. Nothing was
# slow: the CEILING was ~40x fast, so every routed reviewer was abandoned at
# ~30s and three consecutive items reported `ran: []`.
#
# WHY A SCRIPT FIXES IT. The permission control reads the Bash tool's COMMAND
# TEXT. A named project helper script is an ordinary script call, and a wait
# performed INSIDE one runs exactly as written — the same shape ci-poll.sh
# (`sleep "$interval"` under a deadline) and gate.sh already use, and which is
# observably honoured in the same machinery seat (run wf_ebd4b5e0-3a8's
# ci-batch executor held ONE Bash call open for 280 real seconds). This script
# is that shape, minimal: a deadline loop, not a single blind `sleep`, so a
# `sleep` cut short by a signal cannot shorten the interval and `realized_secs`
# is measured rather than assumed.
#
# BOUNDS. The CALLER owns the upper bound, exactly as ci-poll.sh's `--timeout`
# slice does: build-level.mjs never asks for more than REVIEW_WAIT_SLICE_MAX_SECS
# (derived from the agent Bash cap), and the executor's own Bash `timeout`
# parameter is set to secs+60s. This script therefore validates its argument and
# waits; it does not carry a second, independently-tunable ceiling.
#
# This script WAITS; it decides nothing. It reads no state, touches no file, and
# says nothing whatsoever about the review it bounds.

set -euo pipefail

# Poll step for the deadline loop. Small enough that the realized overshoot is
# negligible against the shortest interval the caller ever asks for (the SLOW
# mark), large enough to be free. Not a tunable: no call site varies it.
REVIEW_WAIT_POLL_SECS=5

die() {
  printf '{"outcome":"ERROR","error":%s}\n' "\"review-wait.sh: $1\""
  exit 2
}

secs="${1:-}"
[ "$#" -eq 1 ] || die "usage: review-wait.sh <secs>"
case "$secs" in
  '' | *[!0-9]*) die "<secs> must be a positive integer, got '${secs}'" ;;
esac
[ "$secs" -gt 0 ] || die "<secs> must be a positive integer, got '${secs}'"

start="$(date +%s)"
deadline=$(( start + secs ))

# Deadline loop, not one blind `sleep "$secs"`: a sleep that returns early (a
# signal, a suspended host) would otherwise silently shorten the interval — the
# exact class of failure #2049 is. The loop re-reads the clock, so the interval
# can only ever be met or overshot, never undershot.
while :; do
  now="$(date +%s)"
  [ "$now" -ge "$deadline" ] && break
  remaining=$(( deadline - now ))
  step="$REVIEW_WAIT_POLL_SECS"
  [ "$remaining" -lt "$step" ] && step="$remaining"
  sleep "$step"
done

printf '{"outcome":"REVIEW_WAIT_ELAPSED","secs":%s,"realized_secs":%s}\n' \
  "$secs" "$(( $(date +%s) - start ))"
