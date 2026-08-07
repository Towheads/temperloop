#!/usr/bin/env bash
#
# gate-retry.sh — the CLASSIFIED, CAPPED, BACKED-OFF per-gate retry used by
# scripts/quality-gates.sh (temperloop#403, temperloop#976,
# Towheads/foundation#1297).
#
# Sourced, never executed — same seam as its sibling checkout-freshness.sh,
# which quality-gates.sh already sources. It exists as a lib rather than an
# inline loop for exactly one reason: quality-gates.sh's gate LIST is ~100
# hardcoded `make`/`bash` targets, so the retry policy embedded in that file
# could not be exercised by a test without running the whole suite. Here it
# takes a synthetic gate command and is testable in milliseconds
# (scripts/tests/test_quality_gates_retry.sh).
#
# ── Why classify at all ──────────────────────────────────────────────────
# A retry only ever helps a TRANSIENT failure. Re-running a DETERMINISTIC one
# cannot change its outcome — every attempt after the first is pure burn.
# Live evidence: /build's 3e.5 acceptance gate re-ran a deterministically-
# failing shellcheck (SC2031 on a committed frozen rig script) three times in
# the epic #1443 run before an operator intervened.
#
# Two independent classifiers gate the retry, cheapest first:
#
#   1. SIGNATURE — the failed attempt's captured output matches
#      $GATE_DETERMINISTIC_PATTERN (an ERE; the default names a shellcheck
#      finding code). Classified DETERMINISTIC on attempt 1: no retry at all.
#      Set the pattern EMPTY to disable this classifier.
#   2. BYTE-IDENTICAL OUTPUT — this attempt's output is byte-for-byte the
#      previous FAILED attempt's. Nothing about the run changed, so nothing
#      about the next one will either. This is the GENERAL net under the
#      signature classifier: it needs no per-lint pattern and caps EVERY
#      deterministic gate at two attempts regardless of what it prints.
#
# ── Why back off ─────────────────────────────────────────────────────────
# Towheads/foundation#1297: before this, the retry budget fired back-to-back
# inside a fraction of a second — far too fast to outlast any transient worth
# retrying for. The attempts that ARE legitimate are now separated by
# $GATE_RETRY_BACKOFF seconds * attempt (graduated, mirroring ci-poll.sh's
# gh_retry). 0 restores the old immediate-retry behavior.
#
# ── Settings ─────────────────────────────────────────────────────────────
# Every cap/backoff/pattern below is a config-named setting declared with its
# documented default in workflows/scripts/build/build.config.sh and pinned by
# the kernel setting registry. The `:-` / `-` fallbacks here are the six-layer
# ladder's LAYER 6 (byte-identical, non-vendoring-checkout fallback):
# quality-gates.sh must run standalone in a consuming repo that never sources
# build.config.sh, and /build's 3e.5 acceptance gate deliberately SCRUBS that
# file's settings so the suite runs hermetically at tracked defaults exactly as
# CI does. Keep the two literals in sync.
#
# ── Interface ────────────────────────────────────────────────────────────
#   gate_retry_init                  — allocate the per-attempt capture scratch
#                                      (idempotent; fail-open if mktemp fails)
#   gate_run_with_retry <cmdline> [log-tag]
#                                    — run one gate command line to a verdict
#
# gate_run_with_retry takes the gate's FULL command line as a single string
# (exactly as quality-gates.sh's GATES array stores it), splits it into argv
# with `read -ra` (never `eval`), and sets three globals.
#
# The OPTIONAL second argument is a per-caller LOG TAG naming the scratch file
# this call captures its attempts into (default `attempt`). It exists for the
# PARALLEL scheduler (workflows/scripts/lib/gate-pool.sh, temperloop#1025): the
# byte-identical-output classifier compares THIS gate's attempt N against THIS
# gate's attempt N-1, so concurrent gates sharing one capture file would compare
# each other's output and mis-classify a genuine flake as deterministic (or
# worse, mask one gate's failure signature with another's). Each concurrent
# caller passes a tag unique to itself; the serial caller passes none and keeps
# the pre-parallel single-file behavior byte for byte. The tag is used as a
# FILENAME, so callers pass an integer index — never a raw gate command line.
#
# The three globals it sets:
#
#   GATE_RUN_STATUS    pass | fail | deterministic
#   GATE_RUN_ATTEMPTS  how many attempts were actually spent
#   GATE_RUN_NOTE      one-line classification note ('' unless the verdict
#                      needed explaining — i.e. a retry that went green, or a
#                      deterministic short-circuit)
#
# `deterministic` is a FAILING verdict (the caller records it in `failures`
# exactly like `fail`); the separate status exists so the caller can report
# WHICH failures cost no retries. Returns 0 on pass, 1 otherwise, so a caller
# may branch on either the status or the return code.
#
# Requires `set -o pipefail` in the sourcing shell — the verdict is the GATE's
# own exit status, and the tee capture below would otherwise report tee's 0
# instead (the temperloop#68 swallow). quality-gates.sh sets it at the top of
# the file; this lib re-asserts it defensively so a future sourcing caller
# cannot silently lose the verdict.

set -o pipefail

GATE_MAX_ATTEMPTS="${GATE_MAX_ATTEMPTS:-3}"
GATE_RETRY_BACKOFF="${GATE_RETRY_BACKOFF:-5}"
# `-` (unset-only), NOT `:-`: an explicitly EMPTY value must survive as "off",
# which `:-` would silently replace with the default.
GATE_DETERMINISTIC_PATTERN="${GATE_DETERMINISTIC_PATTERN-SC[0-9][0-9][0-9][0-9]}"

# Scratch dir holding the per-attempt output capture the byte-identical
# classifier compares. FAIL-OPEN: if mktemp is unavailable it stays empty and
# both classifiers degrade to off — the cap and the backoff still apply, and the
# gate VERDICT is never affected. Classification is an optimization; the verdict
# is not. Lowercase-prefixed on purpose: this is PRIVATE implementation state,
# not an operator-tunable setting, and the kernel setting-registry sweep keys
# "operator-tunable" off an ALL-CAPS name.
_gate_retry_tmpdir=""
gate_retry_init() {
  [ -n "$_gate_retry_tmpdir" ] && return 0
  _gate_retry_tmpdir="$(mktemp -d 2>/dev/null || true)"
  [ -n "$_gate_retry_tmpdir" ] || return 0
  # The caller owns process lifetime; clean up on its exit.
  trap 'rm -rf "$_gate_retry_tmpdir"' EXIT
}

# gate_output_digest <file> — fingerprint of one attempt's captured output.
# shasum/sha256sum where available (BSD and GNU userlands each ship one), with
# POSIX `cksum` as the last resort so this stays portable to a bare container.
gate_output_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 <"$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | awk '{print $1}'
  else
    cksum <"$1" | awk '{print $1 "-" $2}'
  fi
}

# GATE_RUN_STATUS / GATE_RUN_ATTEMPTS / GATE_RUN_NOTE are OUT-PARAMS: written
# here, read by the sourcing caller (this is a sourced lib, not a program), so
# the static linter's "appears unused" is a false positive for the whole
# function — hence the blanket disable directive below.
# shellcheck disable=SC2034
gate_run_with_retry() {
  local gate="$1"
  # Per-caller capture-file tag (see the Interface note above). Sanitized to a
  # safe filename so a caller that passes something unexpected can never write
  # outside the scratch dir.
  local tag="${2:-attempt}"
  tag="$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$tag" ] || tag="attempt"
  local attempt=1 prev_digest="" digest rc log=""
  local -a cmd
  # Each gate entry is a full command line; split it into argv (no eval).
  read -ra cmd <<< "$gate"

  GATE_RUN_STATUS="fail"
  GATE_RUN_ATTEMPTS=0
  GATE_RUN_NOTE=""
  [ -n "$_gate_retry_tmpdir" ] && log="$_gate_retry_tmpdir/$tag.log"

  while :; do
    GATE_RUN_ATTEMPTS="$attempt"
    rc=0
    if [ -n "$log" ]; then
      # pipefail (asserted above) is LOAD-BEARING: the pipeline's status must be
      # the GATE's, not tee's. tee keeps the gate's output streaming to the
      # operator while capturing it for the byte-identical classifier.
      "${cmd[@]}" 2>&1 | tee "$log" || rc=$?
    else
      "${cmd[@]}" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      GATE_RUN_STATUS="pass"
      if [ "$attempt" -gt 1 ]; then
        GATE_RUN_NOTE="green on attempt $attempt/$GATE_MAX_ATTEMPTS"
      fi
      return 0
    fi

    # --- classifier 1: deterministic SIGNATURE (spends no retry at all) -----
    if [ -n "$log" ] && [ -n "$GATE_DETERMINISTIC_PATTERN" ] \
      && grep -Eq -- "$GATE_DETERMINISTIC_PATTERN" "$log"; then
      printf '\n::: gate failed DETERMINISTICALLY on attempt %d/%d — NOT retried (signature match, temperloop#976): %s\n' \
        "$attempt" "$GATE_MAX_ATTEMPTS" "$gate" >&2
      GATE_RUN_STATUS="deterministic"
      GATE_RUN_NOTE="deterministic signature on attempt $attempt — a re-run cannot change it"
      return 1
    fi

    # --- classifier 2: BYTE-IDENTICAL output as the previous failed attempt --
    digest=""
    [ -n "$log" ] && digest="$(gate_output_digest "$log")"
    if [ -n "$digest" ] && [ "$digest" = "$prev_digest" ]; then
      printf '\n::: gate failed IDENTICALLY on attempt %d/%d — NOT retried (byte-identical output, temperloop#976): %s\n' \
        "$attempt" "$GATE_MAX_ATTEMPTS" "$gate" >&2
      GATE_RUN_STATUS="deterministic"
      GATE_RUN_NOTE="byte-identical output on attempts $((attempt - 1)) and $attempt — a re-run cannot change it"
      return 1
    fi

    # --- the hard cap -------------------------------------------------------
    if [ "$attempt" -ge "$GATE_MAX_ATTEMPTS" ]; then
      GATE_RUN_STATUS="fail"
      return 1
    fi

    prev_digest="$digest"
    printf '\n::: gate failed on attempt %d/%d — retrying in %ds (transient-flake tolerance, temperloop#403; backoff Towheads/foundation#1297): %s\n' \
      "$attempt" "$GATE_MAX_ATTEMPTS" "$((GATE_RETRY_BACKOFF * attempt))" "$gate" >&2
    if [ "$GATE_RETRY_BACKOFF" -gt 0 ]; then
      sleep "$((GATE_RETRY_BACKOFF * attempt))"
    fi
    attempt=$((attempt + 1))
  done
}
