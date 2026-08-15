#!/usr/bin/env bash
#
# spawn-diagnostic.sh — a SOURCED library providing ONE way to render the
# "why did this spawn fail" detail string that model-comparison's two spawn
# seams (replay.sh's candidate spawn, judge.sh's judge spawn) attach to a
# failure record (temperloop#1553).
#
# WHY THIS EXISTS. Both seams run their spawn with stdout redirected to an
# envelope file and stderr to a scratch file:
#
#     ... spawn ... <"$prompt_file" >"$envelope_file" 2>"$scratch_dir/stderr.txt"
#
# and both then built their failure detail from STDERR ALONE:
#
#     "the candidate runner exited $run_rc: $(head -c 400 .../stderr.txt)"
#
# That is the wrong stream for the runner they actually spawn. `claude -p
# --output-format json` reports an API-level failure as a JSON OBJECT ON
# STDOUT — `{"type":"result","subtype":"error_during_execution",
# "is_error":true,"api_error_status":529,...}` — and says nothing on stderr.
# An empty stderr is therefore the EXPECTED shape for this CLI on failure,
# not an anomaly. Worse, the envelope was read only on the success path: on
# failure the record was emitted and the scratch dir `rm -rf`'d with the
# envelope UNREAD, so the one artifact carrying the reason was destroyed.
#
# The observed damage: a 28-leg live batch whose every failed leg recorded
#
#     "the candidate runner exited 1: "
#
# — a detail string that trails off after a colon, naming no cause at all,
# with the actual vendor diagnostic already deleted by the time anyone read
# the record.
#
# THE CONTRACT this library provides:
#
#   * BOTH STREAMS are consulted, and the detail names WHICH stream each
#     fragment came from, so a reader is never guessing.
#   * The stdout envelope's structured fields are surfaced by name —
#     `is_error`, `subtype`, `api_error_status` first, since those are the
#     three that identify a vendor-side failure — falling back to the whole
#     compact object, and then to a raw excerpt when it does not parse.
#   * There is ALWAYS a stated reason. When neither stream carried anything,
#     the detail says so explicitly rather than trailing off after a colon.
#   * The detail is BOUNDED: each stream contributes at most
#     $_SD_MAX_BYTES bytes, preserving the `head -c 400`
#     discipline the call sites already had, so a verbose failure cannot
#     grow a record without limit.
#   * The output is a SINGLE LINE — newlines, carriage returns and tabs are
#     folded to spaces and runs of spaces squeezed — so a detail stays
#     greppable in a JSONL record stream.
#
# WHY A SHARED LIB rather than a fix at each of the two sites: the two call
# sites had byte-identical bugs because they carried byte-identical code.
# Fixing them separately would re-create the duplication that produced the
# defect (the same reasoning cannot-evaluate.sh's own header records for the
# five `*_cannot_evaluate` clones it replaced).
#
# USAGE (sourced, never executed):
#
#     . "$HERE/../lib/spawn-diagnostic.sh"
#     detail="$(spawn_failure_detail "$rc" "$stderr_file" "$envelope_file" \
#                                    "the candidate runner")"
#
# The caller MUST call this BEFORE tearing down the scratch dir that holds
# the two files — that ordering is the other half of the fix.

# The per-stream byte cap — PRIVATE implementation state, not an
# operator-facing setting (hence the `_` prefix, which is also what keeps it
# out of the setting registry's sweep): it is the `head -c 400` discipline the
# two call sites already carried, hoisted so both halves of a composed detail
# obey the same bound. Overridable only so a fixture can observe truncation
# without generating 400 bytes of output.
: "${_SD_MAX_BYTES:=400}"

# _sd_excerpt <file> — a bounded, single-line excerpt of <file>, or empty
# output when the file is absent, unreadable, empty, or whitespace-only.
_sd_excerpt() {
  local f="${1:-}"
  [ -n "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  head -c "$_SD_MAX_BYTES" "$f" 2>/dev/null \
    | tr '\n\r\t' '   ' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' 2>/dev/null
  return 0
}

# _sd_fold — fold stdin to a bounded single line (the excerpt treatment,
# applied to a stream rather than a file).
_sd_fold() {
  head -c "$_SD_MAX_BYTES" 2>/dev/null \
    | tr '\n\r\t' '   ' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' 2>/dev/null
  return 0
}

# spawn_envelope_diagnostic <envelope-file> — the diagnostic content the
# spawn wrote to STDOUT, rendered as a bounded single line, or empty output
# when the envelope carries nothing usable.
#
# Three tiers, most-structured first:
#   1. a JSON object -> its named diagnostic fields, `is_error`/`subtype`/
#      `api_error_status` leading (the `claude -p --output-format json`
#      failure shape), then the softer `type`/`error`/`message`/`result`;
#   2. a JSON object carrying NONE of those -> the whole compact object;
#   3. anything else non-empty -> a raw excerpt, labelled as unparseable.
spawn_envelope_diagnostic() {
  local f="${1:-}" fields whole raw
  [ -n "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ] || return 0

  if command -v jq >/dev/null 2>&1 && jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    fields="$(jq -r '
      def fld($k):
        if has($k) and (.[$k] != null) and (.[$k] != "")
        then ($k + "=" + (.[$k] | if type == "string" then . else tojson end))
        else empty end;
      [ fld("is_error"), fld("subtype"), fld("api_error_status"),
        fld("type"), fld("error"), fld("message"), fld("result") ]
      | join(" ")' "$f" 2>/dev/null)"
    if [ -n "$fields" ]; then
      printf '%s' "$fields" | _sd_fold
      return 0
    fi
    whole="$(jq -c . "$f" 2>/dev/null)"
    if [ -n "$whole" ] && [ "$whole" != "{}" ]; then
      printf '%s' "$whole" | _sd_fold
      return 0
    fi
    return 0
  fi

  raw="$(_sd_excerpt "$f")"
  [ -n "$raw" ] && printf 'unparseable stdout: %s' "$raw"
  return 0
}

# spawn_failure_detail <rc> <stderr-file> <envelope-file> [<subject>]
#
# The failure-detail string for a spawn that exited non-zero. Always prints
# a stated reason; never a string that ends at a colon.
spawn_failure_detail() {
  local rc="${1:-?}" errfile="${2:-}" envfile="${3:-}" subject="${4:-the runner}"
  local err env
  err="$(_sd_excerpt "$errfile")"
  env="$(spawn_envelope_diagnostic "$envfile")"

  if [ -n "$err" ] && [ -n "$env" ]; then
    printf '%s exited %s: %s | stdout envelope: %s' "$subject" "$rc" "$err" "$env"
  elif [ -n "$err" ]; then
    printf '%s exited %s: %s' "$subject" "$rc" "$err"
  elif [ -n "$env" ]; then
    printf '%s exited %s and wrote nothing to stderr; stdout envelope: %s' \
      "$subject" "$rc" "$env"
  else
    printf '%s exited %s and produced no diagnostic on either stream (stderr empty, stdout envelope absent, empty or unreadable)' \
      "$subject" "$rc"
  fi
  return 0
}
