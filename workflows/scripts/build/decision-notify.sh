#!/usr/bin/env bash
#
# build decision-notify — reach the operator's phone on a blocking-now halt
# (temperloop, foundation#863). The /build level runs unattended, but every
# `blocking-now` human gate (a design-fork, a blocked worker, a failed item, a
# claim conflict, the risky-set modal merge gate, the keystone-spike review
# halt) parks the run on an operator decision with NO safe default — it must
# keep interrupting, every run. The gap the Epic-B retro (F#847) logged: the
# #804 design-fork halted correctly but had no REACH — it sat ~4.5h overnight
# (38% of the run's wall clock) until the operator woke, because a modal ask on
# an interactive-but-idle session pings nothing off-screen.
#
# This helper is the single routing artifact for that reach. Every gate already
# funnels through build.md's `decision_sink_ask(question, options, severity)`
# seam; the orchestrator calls THIS script with the gate's severity + a
# one-line summary, then relays the printed line to the operator's phone via the
# harness `PushNotification` tool. Because ONLY `blocking-now` gates enter that
# seam (the two batch severities — `batch-at-gate`, `batch-at-ritual` — defer to
# the plan note's `## Questions` / the pending-decisions surface and never touch
# it), routing the notify decision by severity here makes the
# "notify on a blocking-now halt, NEVER on a timed gate or a non-blocking
# question" contract structural rather than a thing the prose has to remember at
# each of five call sites.
#
#   decision-notify.sh <severity> <summary>
#       severity ∈ blocking-now | batch-at-gate | batch-at-ritual
#                  (the AskUserQuestion severity taxonomy — the closed enum;
#                   an unrecognized value is a usage error, never a silent skip)
#       summary  = the human one-line halt description the orchestrator composed
#                  (e.g. "temperloop /build halted — design-fork on <slug> needs
#                   your decision"). Truncated to 200 chars (mobile OSes clip).
#
# Behavior — a CLOSED outcome set, branched on the EXIT CODE:
#   blocking-now  → print the (truncated) summary on stdout,           exit 0
#                   AND run $BUILD_DECISION_NOTIFY_CMD "<summary>" if set.
#                   The orchestrator relays the stdout line via PushNotification.
#   batch-at-*    → print nothing, emit nothing,                       exit 10
#                   (a correctly-skipped non-blocking severity, NOT an error).
#   bad args / unknown severity → message on stderr,                   exit 2
#
# Two emission channels, both fed the same truncated summary:
#   1. stdout → the orchestrator relays it via the harness `PushNotification`
#      tool (pushes to the phone when Remote Control is connected; a no-op that
#      the harness reports as "not sent" when the operator is actively at the
#      terminal — so it is harmless on the modal path and reaches them only when
#      they have walked away, which is exactly the #804 case).
#   2. $BUILD_DECISION_NOTIFY_CMD (default empty) → an OPTIONAL scriptable channel
#      an operator can wire for phone reach independent of Remote Control (ntfy /
#      pushover / terminal-notifier / a webhook). It is also the test-injection
#      seam: a test points it at a marker-writer and asserts the marker is
#      written on a blocking-now halt and absent on a batch severity. It is a
#      TRUSTED config string (never user input); the summary is passed as a
#      single quoted argument, so a well-behaved command receives it verbatim.
set -euo pipefail

readonly PUSH_MAX=200   # PushNotification's own documented body cap

usage() {
  echo "usage: decision-notify.sh <blocking-now|batch-at-gate|batch-at-ritual> <summary>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
severity="$1"
summary="$2"
[ -n "$summary" ] || { echo "decision-notify: empty summary" >&2; exit 2; }

case "$severity" in
  blocking-now) ;;                       # the one severity that reaches the operator
  batch-at-gate|batch-at-ritual)
    exit 10 ;;                           # a real severity, deliberately not notified
  *)
    echo "decision-notify: unknown severity '$severity'" >&2
    usage ;;
esac

# Truncate to the push cap. NOTE the count is locale-conditional: `${#s}` /
# `${s:0:N}` count CHARACTERS under a UTF-8 locale but BYTES under C/POSIX (a
# minimal CI runner with LANG unset), so under a byte-locale an over-cap summary
# carrying em-dashes could be cut a few chars short or split a multibyte
# sequence. This is benign in practice — summaries run ~60–100 chars so this
# guard almost never fires, and the cap only exists to honor PushNotification's
# 200-char limit (mobile OSes clip anyway) — so we do not force a locale (no
# portable UTF-8 name exists across macOS + every Linux runner). The test
# asserts the length invariant (≤ cap) under whatever locale CI runs.
if [ "${#summary}" -gt "$PUSH_MAX" ]; then
  summary="${summary:0:$PUSH_MAX}"
fi

# Optional scriptable channel + test-injection seam. Empty default → skipped.
# Referenced with `:-` so `set -u` is satisfied when the orchestrator did not
# source build.config.sh (build.config.sh owns the registered default, empty).
notify_cmd="${BUILD_DECISION_NOTIFY_CMD:-}"
if [ -n "$notify_cmd" ]; then
  # Trusted config string; the summary is one quoted arg. The `\"\$summary\"`
  # (backslash-escaped) form is LOAD-BEARING: it defers the summary's expansion
  # to eval's SECOND pass, where it lands INSIDE double quotes — so a summary
  # containing " ; $HOME or a backslash is inserted as literal text, never
  # reparsed as shell syntax. Do NOT "simplify" to `\"$summary\"` (expanding in
  # the first pass) — that reintroduces a shell-injection breakout.
  #
  # Redirect the channel's OWN stdout to stderr: a real channel (`ntfy publish`,
  # a non-`-s` `curl`, a webhook helper) is chatty on stdout, and this script's
  # stdout is the clean summary line the orchestrator captures and relays — the
  # channel's receipt/progress noise must never pollute it. Its diagnostics stay
  # visible on stderr. `|| true` keeps the gate fail-open: a failing or malformed
  # operator channel never aborts the halt (same posture as the quota gate).
  eval "$notify_cmd \"\$summary\"" >&2 || true
fi

# The primary reach: the orchestrator relays this exact line via PushNotification.
# `|| true` keeps the closed 0/10/2 outcome set airtight even on an EPIPE from a
# closed downstream pipe (can't arise under the documented `$(...)` capture, but
# keeps `set -e` from substituting an unlabeled fourth exit status).
printf '%s\n' "$summary" || true
exit 0
