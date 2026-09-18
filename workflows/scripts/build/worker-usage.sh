#!/usr/bin/env bash
#
# worker-usage.sh — the emitted-shell seam for /build's per-item WORKER COST
# capture (temperloop#2065 "worker-cost-capture", epic #2062 "new-work
# dual-build harness").
#
#   worker-usage.sh clock
#     {"outcome":"WORKER_CLOCK","epoch_s":N}
#
#   worker-usage.sh emit <seat> <model> <outcome-ref> [repo]
#     {"outcome":"WORKER_USAGE","epoch_s":N,
#      "usage_source":"unavailable"|"cli-envelope",
#      "input_tokens":N|null,"output_tokens":N|null}
#
# WHY THIS SCRIPT EXISTS. claude/workflows/build-level.mjs's per-item worker
# is spawned through the Workflow runtime's `agent()` primitive, which
# returns NO usage envelope, and the runtime itself has no timer
# (`Date.now()` throws — see that file's own STEP CEILING block, DESIGN NOTE
# 1's sibling). Both gaps are closed the SAME way every other shell-only fact
# that file needs is closed: an emitted-shell machinery call (DESIGN NOTE 1,
# "the runMachinery bridge"). This script is that bridge — the SAME pattern
# review-wait.sh established for giving that runtime a wall-clock tick it
# otherwise has none of (temperloop#2049).
#
# `clock` is a bare `date` read with NO side effect — build-level.mjs calls
# it once before spawning a worker (or the CI_FAIL_RETRY_BUDGET loop's
# CI-fix re-spawn) and reads the elapsed wall-clock itself as plain integer
# arithmetic on the two readings (never Date.now() — only that call and
# Math.random() throw in that runtime, not arithmetic on a value already in
# hand).
#
# `emit` does two things: (1) it is that SAME worker's "after" wall-clock
# reading, so a caller that only needs the closing edge does not pay for a
# second `clock` call; and (2) it calls model-usage-envelope.sh's shared
# model_usage_emit_from_envelope — the SAME helper pipeline-drive.sh's A7/A8
# and pipeline-retro-judge-spawn.sh's A9 already call — so the build worker
# joins their per-seat attribution stream (ADR 0026) as a FOURTH emitting
# seat, "build-worker" (see workflows/scripts/lib/model-usage-envelope.sh's
# own header, which names it).
#
# THE HONEST DEGRADE. No `claude -p --output-format json` envelope exists for
# a Workflow agent() call — there is nothing on this script's stdin to
# parse — so `emit` ALWAYS calls model_usage_emit_from_envelope with an EMPTY
# blob (`{}`), which is its own documented fail-open path: it appends an
# ATTRIBUTION-ONLY record (seat + model + outcome ref, usage_source
# "unavailable", no tokens) rather than fabricating a token count. This
# script's OWN stdout mirrors that same degrade (`input_tokens`/
# `output_tokens`: null) rather than guessing a number, matching
# model-usage-envelope.sh's own FAIL-OPEN, WARN-DON'T-DROP contract. Wiring a
# real envelope in later needs no further plumbing here: `{}` on the line
# below is the ONE thing that would change, and the parsed fields would then
# flow through byte-for-byte — build-level.mjs's own WORKER_USAGE handling
# already reads whatever `usage_source`/`input_tokens`/`output_tokens` this
# script reports, it does not assume "unavailable".
#
# PORTABILITY. `date +%s` (whole seconds — no GNU `%N` dependency: stock
# macOS ships BSD date, which lacks it). A multi-minute worker call does not
# need millisecond precision, and epoch SECONDS is what
# model-usage-envelope.sh's own --duration-ms convention is measured against
# elsewhere in this repo.
#
# FAIL-OPEN. A cost-ledger entry must never be the thing that stalls a
# build: both subcommands always print a well-formed JSON line, even when
# the durable attribution write itself could not run (a missing/unreadable
# model-usage-envelope.sh, a missing/non-executable emit-model-usage.sh —
# model_usage_emit_from_envelope's own header covers that fail-open path;
# see EMIT SCRIPT RESOLUTION below) or `jq` is absent on this host.
#
# EMIT SCRIPT RESOLUTION. model-usage-envelope.sh's own function takes the
# emit script's path as an explicit argument (its documented TEST SEAM) — we
# resolve it relative to THIS script's own directory
# (workflows/scripts/emit-model-usage.sh), never a $PATH lookup, so a vendored
# checkout with no `emit-model-usage.sh` on PATH still degrades cleanly
# (the function's own `[ ! -x "$emit_script" ]` guard no-ops rather than
# erroring).
#
# Kept bash-3.2-friendly (macOS dev shell + Linux CI) — no mapfile, no
# associative arrays, matching the rest of workflows/scripts/build/.

set -euo pipefail

die() {
  printf '{"outcome":"ERROR","error":%s}\n' "\"worker-usage.sh: $1\""
  exit 2
}

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || die "could not resolve this script's own directory"
ENVELOPE_LIB="$self_dir/../lib/model-usage-envelope.sh"
EMIT_SCRIPT="$self_dir/../emit-model-usage.sh"

cmd="${1:-}"
case "$cmd" in
  clock)
    printf '{"outcome":"WORKER_CLOCK","epoch_s":%s}\n' "$(date +%s)"
    ;;
  emit)
    seat="${2:-}"
    model="${3:-}"
    outcome_ref="${4:-}"
    repo="${5:-}"
    [ -n "$seat" ] && [ -n "$outcome_ref" ] || die "usage: worker-usage.sh emit <seat> <model> <outcome-ref> [repo]"
    epoch_s="$(date +%s)"
    # THE HONEST DEGRADE (see header): `{}` — no envelope exists for a
    # Workflow agent() call. Sourced only if present, so a checkout missing
    # this sibling library (a stale vendored copy) still prints a clean
    # WORKER_USAGE line — the durable attribution write is a best-effort
    # side effect, never a precondition for this script's own output.
    if [ -f "$ENVELOPE_LIB" ]; then
      # shellcheck source=../lib/model-usage-envelope.sh
      . "$ENVELOPE_LIB"
      printf '{}' | model_usage_emit_from_envelope "$seat" "$model" "$outcome_ref" "$repo" "$EMIT_SCRIPT"
    fi
    printf '{"outcome":"WORKER_USAGE","epoch_s":%s,"usage_source":"unavailable","input_tokens":null,"output_tokens":null}\n' \
      "$epoch_s"
    ;;
  *)
    die "usage: worker-usage.sh clock | emit <seat> <model> <outcome-ref> [repo]"
    ;;
esac
