#!/usr/bin/env bash
#
# pipeline-retro-judge-spawn.sh — the CREDENTIAL-BEARING spawn site for the
# overlay `/retro --pending` judge (temperloop#1148).
#
# ── THE BUG THIS CLOSES ────────────────────────────────────────────────────
# Phase R's judge used to be spawned TWO LEVELS DEEP, and the credential was
# lost between them:
#
#   pipeline-cron.sh          (cron process — sources build.config.sh, which
#     │                        sources the gitignored build.config.local.sh
#     │                        LAST, so a host credential IS in this env)
#     └─ pipeline-drive.sh    (same process tree — credential still in env)
#          └─ claude -p "/pipeline-drive <payload>"      ← session A: authenticates
#               └─ Bash tool: claude -p "/retro --pending …"  ← session B: DID NOT
#
# Session A authenticates fine and does real work in the same tick. Session B
# is spawned from INSIDE session A's Bash tool, and a Claude Code session does
# not forward its credential environment to a Bash-tool child — so on a headless
# host whose interactive OAuth session has expired, hop two died before turn 1
# while hop one was demonstrably healthy. The failure was near-invisible: it
# only ever incremented a `safe_failed` counter in the wake record.
#
# ── THE FIX ────────────────────────────────────────────────────────────────
# Stop INHERITING the credential across that hop and RE-DERIVE it at the spawn
# site instead. This script is the process that actually invokes `claude -p`,
# and it sources the host config ladder ITSELF — so whatever the caller's
# environment did or did not carry, the credential reaches the judge. It is the
# same move `tidy-nightly.sh` already makes before its own nested invocation
# (the established in-repo pattern for exactly this problem), lifted to the
# retro-judge seam and given a machine-readable outcome contract.
#
# Two hardening properties beyond the re-derive:
#
#   LOUD ON AUTH FAILURE. An auth failure at this hop is classified (`status:
#   "auth-failed"`), announced on stderr, pushed through the operator notify
#   channel pipeline-cron.sh already uses, and returned as a DISTINCT exit code
#   — never folded into a generic counter nobody reads. `pipeline-drive.md`'s
#   retro-judge action records the failure with the stable token
#   `retro-judge-auth-failed`, which `pipeline-retro-health.sh` then reads back
#   out of the lake as a durable `defect_kind: "auth"` verdict.
#
#   THE CREDENTIAL IS NEVER EMITTED. Its VALUE is never printed, logged, or
#   passed on an argv (so it cannot appear in `ps`). Everything this script
#   emits is run through _redact(), which replaces any occurrence of a live
#   credential value with `<redacted>` — belt and braces over the fact that we
#   never intentionally print it. Only PRESENCE and a SOURCE LABEL are ever
#   reported. Same standing rule tidy-nightly.sh states: the token belongs in
#   the gitignored, mode-600 build.config.local.sh and nowhere else.
#
# ── OUTPUT CONTRACT ────────────────────────────────────────────────────────
# Exactly one JSON object on stdout, always (even on failure):
#
#   {"spawn":"retro-judge", "board":"<n>", "model":"<m>",
#    "status":"ok"|"auth-failed"|"spawn-failed"|"dry-run",
#    "credential_present":<bool>, "credential_source":"<label>",
#    "exit":<n>, "judge":"<the judge's own stdout, redacted>",
#    "stderr_head":"<first 400 chars of its stderr, redacted>",
#    "note":"<one line>"}
#
# `credential_source` is a SOURCE LABEL, not a validity claim — this script
# never validates a token, it only names which one was in play, so a revoked
# but present token still reaches the judge and fails THERE, attributably.
#
# Exit codes (the caller may key on these instead of parsing):
#   0  ok / dry-run          2  usage error
#   3  auth-failed           4  spawn-failed (non-zero exit, not auth-shaped)
#
# Usage:
#   pipeline-retro-judge-spawn.sh --board <n> [--model <m>] [--dry-run]
#
# Config (resolved AFTER the ladder is sourced, so a host file wins):
#   RETRO_JUDGE_MODEL   model the judge runs under (build.config.sh owns it)
#   CLAUDE_BIN          the claude binary / test-double seam
#   PIPELINE_NOTIFY_CMD operator notify command (else osascript, else stderr)
#
# Kept bash-3.2 / BSD portable, matching the rest of workflows/scripts/build/.

set -uo pipefail

board=""
model=""
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --board) board="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'pipeline-retro-judge-spawn.sh: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$board" in
  ''|*[!0-9]*) printf 'pipeline-retro-judge-spawn.sh: --board <n> is required\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf '{"spawn":"retro-judge","status":"spawn-failed","note":"jq not found"}\n'
  exit 4
}

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# model-usage attribution emit (temperloop#1255, epic #1225): this is seat A9
# of the L0 usage-capture-feasibility spike's emit-feasible set — the judge
# spawn below captures a `claude -p --output-format json` envelope, and
# model_usage_emit_from_envelope is the shared extraction pipeline-drive.sh's
# A7/A8 sites also use.
# shellcheck source=workflows/scripts/lib/model-usage-envelope.sh
[ -f "$HERE/../lib/model-usage-envelope.sh" ] && . "$HERE/../lib/model-usage-envelope.sh"
MODEL_USAGE_EMIT="$HERE/../emit-model-usage.sh"

# ── model-usage lake SINK — THE CALLER PINS IT (temperloop#1565) ──────────────
# THIS PINS THE MODEL-USAGE STREAM ONLY. The retro-runs stream is untouched and
# must stay that way: pipeline-retro-health.sh resolves retro-runs
# CHECKOUT-RELATIVE precisely because this wrapper sets no retro-runs override
# and the overlay judge it spawns writes that stream under whatever checkout
# invoked it. MODEL_USAGE_RAW_DIR is read by exactly one script
# (emit-model-usage.sh, which writes model-usage-<YYYY-MM>.jsonl and nothing
# else), so pinning it cannot move a retro-runs row.
#
# WHY (the model-usage half): emit-model-usage.sh's own default climbs two
# levels from its own file location, which is right for a stranger's standalone
# kernel checkout and wrong here — the pipeline runs the kernel copy VENDORED
# under a consuming checkout (…/foundation.cron/kernel/), so the climb landed on
# the vendored kernel's own root and every judge-spawn record went to a stub
# meta/data/raw/ holding only a README, invisible to both real lakes. The
# emitter cannot know which checkout is canonical; this caller can, so it says.
#
# Same canonical sink as pipeline-cron.sh:299, byte-for-byte in the default
# literal, for the reason stated there: the sink is fixed regardless of which
# checkout the run started from. DUPLICATE SEAM, documented here per
# setting-registry.tsv's own owning-script convention (the PIPELINE_OPERATOR
# precedent — a fallback duplicated in a non-owning consuming script is
# documented at each duplicate site and records NO second registry row):
# MODEL_USAGE_RAW_DIR's row keeps naming emit-model-usage.sh as owner, with that
# script's own literal as the registered default. This site is a consuming
# caller's pin, never a second source of truth.
#
# `${MODEL_USAGE_RAW_DIR:-…}` — an already-set value passes through UNTOUCHED
# and always wins (the live test seam). $HOME is guarded because this script
# runs under `set -u`: with MODEL_USAGE_RAW_DIR, PIPELINE_RAW_DIR and HOME ALL
# unset there is no sink to name, so we set nothing and leave the emitter on its
# own checkout-relative default. Telemetry never aborts a judge spawn.
if [ -n "${MODEL_USAGE_RAW_DIR:-}" ] || [ -n "${PIPELINE_RAW_DIR:-}" ] || [ -n "${HOME:-}" ]; then
  export MODEL_USAGE_RAW_DIR="${MODEL_USAGE_RAW_DIR:-${PIPELINE_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}}"
fi

# ── Re-derive the credential from the host config ladder ─────────────────────
# THE WHOLE POINT OF THIS SCRIPT. build.config.sh sources the machine conf and
# the gitignored build.config.local.sh, so a host credential lands in THIS
# process's environment regardless of what the caller's environment carried.
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"

# EXPORT explicitly (the tidy-nightly.sh precedent). build.config.local.sh's
# documented idiom is `: "${VAR:=…}"` plus a SEPARATE `export VAR` line, but a
# host file written without that second line would bind the value in this shell
# only and never cross into the `claude -p` child — a set-but-unexported token
# that fails silently and looks exactly like no token at all. Exporting here
# makes the wiring correct however the host file was written. Never echo them.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then export CLAUDE_CODE_OAUTH_TOKEN; fi  # setting:exempt — host-supplied credential, presence-checked only; never an operator-tunable setting
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then export ANTHROPIC_API_KEY; fi  # setting:exempt — host-supplied credential, presence-checked only; never an operator-tunable setting

credential_present=false
credential_source="interactive-session"
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then  # setting:exempt — presence probe on a host-supplied credential
  credential_present=true
  credential_source="oauth-token"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then  # setting:exempt — presence probe on a host-supplied credential
  credential_present=true
  credential_source="api-key"
fi

: "${CLAUDE_BIN:=claude}"
[ -n "$model" ] || model="${RETRO_JUDGE_MODEL:-claude-sonnet-5}"

# Replace any live credential VALUE with a placeholder in anything we emit.
# Pure parameter substitution — never a `sed`/`grep` argv, which would expose
# the value in `ps`. This is defence in depth: nothing here intentionally
# prints a credential, and this guarantees that stays true of pass-through
# child output too.
_redact() {
  local s="$1"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && s="${s//$CLAUDE_CODE_OAUTH_TOKEN/<redacted>}"  # setting:exempt — redaction probe on a host-supplied credential
  [ -n "${ANTHROPIC_API_KEY:-}" ] && s="${s//$ANTHROPIC_API_KEY/<redacted>}"  # setting:exempt — redaction probe on a host-supplied credential
  printf '%s' "$s"
}

# The operator-visible channel. Mirrors pipeline-cron.sh Step 3's ladder
# (injectable command → osascript banner → stderr) and ALWAYS also writes the
# line to stderr, so a headless cron log carries it even where no GUI notifier
# exists. Fail-open: a broken notifier can never wedge the spawn.
_notify_loud() {
  local msg="$1"
  printf '%s\n' "$msg" >&2
  if [ -n "${PIPELINE_NOTIFY_CMD:-}" ]; then
    "$PIPELINE_NOTIFY_CMD" "$msg" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"pipeline retro-judge\"" >/dev/null 2>&1 || true
  fi
  return 0
}

_emit() {  # $1 status  $2 exit  $3 judge-stdout  $4 stderr-head  $5 note
  jq -nc --arg b "$board" --arg m "$model" --arg s "$1" --argjson x "$2" \
    --argjson cp "$credential_present" --arg cs "$credential_source" \
    --arg j "$(_redact "$3")" --arg e "$(_redact "$4")" --arg n "$5" \
    '{spawn:"retro-judge",board:$b,model:$m,status:$s,
      credential_present:$cp,credential_source:$cs,exit:$x,
      judge:$j,stderr_head:$e,note:$n}'
}

# No env credential in scope: WARN, never refuse. An attended host with a live
# interactive session authenticates fine with nothing exported, so refusing
# here would break the very path that still works; but on the unattended host
# this is the single most likely cause of the failure about to happen, and the
# operator should see it named BEFORE the spawn, not inferred afterwards.
if [ "$credential_present" != true ]; then
  _notify_loud "retro-judge: NO host credential in scope (falling back to the interactive session, which expires on a headless host). Remedy: export CLAUDE_CODE_OAUTH_TOKEN from the gitignored mode-600 $HERE/build.config.local.sh"
fi

if [ "$dry_run" -eq 1 ]; then
  _emit "dry-run" 0 "" "" "resolved the spawn without invoking the judge"
  exit 0
fi

# ── The ONE-HOP spawn ───────────────────────────────────────────────────────
out=""
err_file="$(mktemp -t retro-judge-spawn.XXXXXX 2>/dev/null || echo "/tmp/retro-judge-spawn.$$")"
out="$("$CLAUDE_BIN" -p "/retro --pending --board $board" --model "$model" --output-format json 2>"$err_file")"
rc=$?
err_head="$(head -c 400 "$err_file" 2>/dev/null || true)"
rm -f "$err_file"

# model-usage attribution (temperloop#1255, spike seat A9): `out` captured
# above IS the `claude -p --output-format json` envelope, win or lose (an
# auth/spawn failure is classified below by SHAPE, not by skipping this
# emit) — one record per judge spawn, board-scoped outcome_ref (the judge
# handles a whole board's retro-pending trackers per call, not one issue).
model_usage_emit_from_envelope "retro-judge" "$model" "issue:board-$board" "" \
  "$MODEL_USAGE_EMIT" <<<"$out"

# ── Classify ────────────────────────────────────────────────────────────────
# An auth failure is recognised by SHAPE, not by exit code: a nested headless
# session can fail to authenticate and still exit 0 with the error in its own
# JSON envelope (the same "exits success having done nothing" class temperloop
# #1150 documents). So scan the combined output for the auth vocabulary the
# CLI and the API emit, and let that outrank the exit code either way.
combined="$out
$err_head"
auth_re='invalid[ _-]?api[ _-]?key|authentication[ _]error|authentication failed|invalid[ _]bearer|unauthorized|(http|status)[ _]?401|oauth token (has )?expired|token (has )?expired|credentials? (have )?expired|please run /login|not logged in|log ?in to claude'

status="ok"
note="judge spawned at one level of nesting with the ${credential_source} credential in scope"
if printf '%s' "$combined" | grep -Ei "$auth_re" >/dev/null; then
  status="auth-failed"
  note="retro-judge-auth-failed: the nested judge could not authenticate (credential_source=${credential_source}, present=${credential_present}) — no judgment ran"
elif [ "$rc" -ne 0 ]; then
  status="spawn-failed"
  note="the nested judge exited ${rc} with no auth-shaped error — see stderr_head"
fi

if [ "$status" = "auth-failed" ]; then
  _notify_loud "retro-judge AUTH FAILURE on board $board — the judge could not authenticate (credential source: $credential_source). No retrospective ran this tick. Check the credential in $HERE/build.config.local.sh."
  _emit "$status" "$rc" "$out" "$err_head" "$note"
  exit 3
fi
if [ "$status" = "spawn-failed" ]; then
  _notify_loud "retro-judge SPAWN FAILURE on board $board — the judge exited $rc. No retrospective ran this tick."
  _emit "$status" "$rc" "$out" "$err_head" "$note"
  exit 4
fi

_emit "$status" "$rc" "$out" "$err_head" "$note"
exit 0
