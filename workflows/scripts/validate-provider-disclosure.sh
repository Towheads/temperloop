#!/usr/bin/env bash
#
# validate-provider-disclosure.sh — the allowlist/disclosure-log pairing
# validator (temperloop#1250, epic #1225, ADR 0028:
# docs/adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md).
#
# GATE SCOPE — read this before extending it. This validator owns
# LOG-FORMAT VALIDITY and ALLOWLIST-MEMBERSHIP CHECKING ONLY:
#
#   1. COMMITTED-CEILING checks — the provider allowlist is a committed,
#      git-tracked, repo-scoped file (never under .temperloop/, never an
#      env var, never a $HOME config), it parses, every provider name is
#      well-formed, and it still names the trusted default provider
#      ("anthropic" — ADR 0028 decision 3: the judge stays on the trusted
#      default provider by default).
#   2. NO-WIDEN checks — if a personal narrowing override is present, every
#      provider it names must already be in the committed ceiling. An
#      attempted widen is REJECTED (fails the gate), never silently
#      dropped.
#   3. DISCLOSURE-LOG FORMAT checks — every entry is well-formed JSON with
#      EXACTLY the fixed field set (schema_version, ts, provider, item_ref,
#      seq, prev_hash, hash — never content), and the hash chain is intact:
#      an entry's own `hash` matches its recomputed fields, and its
#      `prev_hash` matches the immediately preceding entry's `hash` (or the
#      literal "genesis" for the first entry). Plus the watermark-anchor
#      checks (TRUNCATED / REFORGED / WATERMARK-STALE / WATERMARK-MISSING).
#
#      WHAT THIS PROVES, PRECISELY — do not overstate it. The chain makes an
#      entry REWRITTEN IN PLACE, or DELETED FROM THE INTERIOR of an otherwise
#      intact file, mechanically detectable. It does NOT, on its own, detect
#      truncation of the log's TAIL, deletion of the WHOLE log, or a full
#      RE-FORGE — an unanchored chain records nothing about its own length,
#      and an unkeyed one can be rebuilt end to end by anyone who can write
#      the file. The sibling watermark anchor
#      (`disclosure-log.watermark`, written by pa_disclose) closes the first
#      two and makes the third loud, but the watermark is ITSELF an untracked
#      local file beside the log: it raises the cost of casual tampering and
#      does not defeat an attacker who can write both files. Anchoring it
#      beyond local write reach (committing or signing it) is a separate,
#      open question. See allowlist.sh's own header for the full statement.
#   4. DISCLOSURE-LOG MEMBERSHIP checks — every logged entry's provider is
#      in the CURRENT effective allowlist (committed narrowed by any
#      personal override). A logged provider that the allowlist no longer
#      (or never did) allow is a violation.
#
#   5. SEND-VS-LOG COVERAGE cross-check (temperloop#1258 — the half #1250's
#      own acceptance deferred to replay-execute-and-score, now IN SCOPE).
#      Every actual SEND to a non-default provider must have produced a
#      matching disclosure-log entry. The send side is the per-seat
#      attribution raw lake emit-model-usage.sh writes (temperloop#1253 gave
#      those records their `provider` field, which is what made this check
#      possible at all); the two are joined on (provider, item_ref) —
#      the attribution record's own `outcome_ref` IS the disclosure entry's
#      `item_ref`, both spelled "(issue|pr):<ref>". A record naming a
#      non-default provider with no matching log entry is a
#      SEND-WITHOUT-DISCLOSURE failure.
#
#      DIRECTIONALITY, stated so it is not mistaken for a symmetric check:
#      the log may legitimately run AHEAD of the sends and never behind
#      them. replay.sh's `execute` discloses BEFORE it sends and refuses the
#      send if the disclosure fails, so a disclosed-but-never-sent entry is
#      the normal shape of a spawn that then failed — not a violation. The
#      violation is the other direction only: a send with no disclosure.
#
#      A default-provider ("anthropic") send is skipped by construction —
#      ADR 0028 decision 3 makes the trusted default the un-disclosed
#      baseline, so requiring a log entry for it would make the log a
#      record of ordinary pipeline traffic rather than of provider
#      exposure.
#
# Both the committed allowlist and the disclosure log are read via
# workflows/scripts/model-comparison/allowlist.sh (sourced) — this script
# adds no independent parsing of either artifact, so the validator and the
# module's own writer (pa_disclose) can never silently disagree on shape.
#
# FAIL-CLOSED DISCIPLINE (mirroring workflows/scripts/validate-feature-docs.sh):
# a genuine "this data is malformed/inconsistent" verdict is a FAIL; an
# inability to evaluate at all (jq missing, an unreadable file) is a hard
# abort (exit 1 with a CANNOT-EVALUATE message), never a silently-reported
# pass. That is enforced, not just asserted: every input file this script
# reads is checked for READABILITY before it is read, and a chain verdict
# that comes back non-zero with an EMPTY violation list — the shape an
# unreadable log produced, indistinguishable from clean to a caller reading
# only the printed lines — is itself treated as CANNOT EVALUATE.
#
# Usage:
#   workflows/scripts/validate-provider-disclosure.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (FIXTURE-TEST SEAM — same names allowlist.sh itself reads, so
# a fixture repo just points all three at a scratch dir). They are honoured
# ONLY alongside PROVIDER_ALLOWLIST_TEST_SEAM=1, and this script hard-fails
# if a non-default committed-file override is present without it: otherwise
# `PROVIDER_ALLOWLIST_COMMITTED_FILE=/tmp/widened.txt` repoints the ceiling
# from the environment AND satisfies this gate by construction (a file
# outside the repo skips the git-tracked check, and a widened file names
# `anthropic` by construction), which is exactly the "never an env var"
# property ADR 0028 decision 1 requires.
#   PROVIDER_ALLOWLIST_TEST_SEAM
#   PROVIDER_ALLOWLIST_COMMITTED_FILE
#   PROVIDER_ALLOWLIST_LOCAL_FILE
#   PROVIDER_DISCLOSURE_LOG_FILE
#
# One more, for check 5's SEND side — the existing raw-lake dir seam every
# other consumer of that stream already honours (emit-model-usage.sh writes
# it, validate-model-usage-emit.sh and tagging.sh read it), so no new,
# check-5-only override is invented here:
#   MODEL_USAGE_RAW_DIR   the per-seat attribution raw-lake dir scanned for
#                         `model-usage-*.jsonl` sends. An ABSENT dir is
#                         legal (a checkout that never spawned a seat); a
#                         present-but-unreadable dir or file is CANNOT
#                         EVALUATE, never a pass.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST_LIB="$SCRIPT_DIR/model-comparison/allowlist.sh"

if [[ ! -f "$ALLOWLIST_LIB" ]]; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — $ALLOWLIST_LIB is missing" >&2
  exit 1
fi

# Read the inherited committed-file override BEFORE sourcing — the library
# overwrites the variable with the committed default when the test seam is
# off, so this is the only point at which "was it set in the environment?" is
# still answerable. `${VAR+x}` (not `:-`) so this is not a settings seam of
# its own.
_PA_ENV_COMMITTED=""
if [[ -n "${PROVIDER_ALLOWLIST_COMMITTED_FILE+x}" ]]; then
  _PA_ENV_COMMITTED="$PROVIDER_ALLOWLIST_COMMITTED_FILE"
fi
_PA_DEFAULT_COMMITTED="$SCRIPT_DIR/model-comparison/provider-allowlist.txt"
if [[ -n "$_PA_ENV_COMMITTED" && "$_PA_ENV_COMMITTED" != "$_PA_DEFAULT_COMMITTED" \
      && "${PROVIDER_ALLOWLIST_TEST_SEAM:-0}" != "1" ]]; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — PROVIDER_ALLOWLIST_COMMITTED_FILE is set to a non-default path ($_PA_ENV_COMMITTED) without PROVIDER_ALLOWLIST_TEST_SEAM=1. The committed ceiling is never repointed from the environment (ADR 0028 decision 1); refusing to validate a ceiling this gate did not choose." >&2
  exit 1
fi

# shellcheck source=workflows/scripts/model-comparison/allowlist.sh
source "$ALLOWLIST_LIB"

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — jq not found" >&2
  exit 1
fi

failures=()
TRUSTED_DEFAULT_PROVIDER="anthropic"
# Hoisted out of check 1's `else` branch: check 5 needs it to resolve the
# attribution raw-lake default, and check 1 legitimately never reaches that
# branch when the committed allowlist is missing — leaving it unset there
# would abort check 5 under `set -u` for an unrelated reason.
repo_root_for_git="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Committed ceiling: present, tracked, well-formed, names the default.
# ---------------------------------------------------------------------------
committed_file="$(pa_committed_file)"

case "$committed_file" in
  */.temperloop/*)
    failures+=("COMMITTED-LOCATION  $committed_file — the committed allowlist must never live under the gitignored .temperloop/ runtime dir (ADR 0028 decision 1)")
    ;;
esac

if [[ ! -f "$committed_file" ]]; then
  failures+=("COMMITTED-MISSING  $committed_file — no committed provider allowlist found")
elif [[ ! -r "$committed_file" ]]; then
  # NOT a failure line: an unreadable ceiling means the checks below silently
  # read NOTHING (`malformed=0`, `pa_committed_list` falls back to the
  # built-in default, `anthropic` is "present" by construction) and the gate
  # PASSES on a file it never saw. Hard abort instead.
  echo "validate-provider-disclosure: CANNOT EVALUATE — the committed allowlist ($committed_file) exists but is not readable; aborting rather than reporting a pass on a ceiling this gate could not read" >&2
  exit 1
else
  # Must be a real git-tracked path, not merely present on disk (a fresh
  # `touch` would satisfy -f but carries no review/commit history). Only
  # meaningful for a file actually inside this repo checkout — a test
  # fixture deliberately points PROVIDER_ALLOWLIST_COMMITTED_FILE at a
  # scratch path outside the repo (to exercise narrowing/disclosure-log
  # behavior in isolation), where "git-tracked" has no meaning to check.
  case "$committed_file" in
    "$repo_root_for_git"/*)
      if ! git -C "$repo_root_for_git" ls-files --error-unmatch -- "$committed_file" >/dev/null 2>&1; then
        failures+=("COMMITTED-NOT-TRACKED  $committed_file — exists on disk but is not git-tracked; the committed ceiling must change only through a reviewed commit")
      fi
      ;;
  esac

  malformed=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    [[ -z "$line" ]] && continue
    if ! pa_valid_provider_name "$line"; then
      failures+=("MALFORMED-PROVIDER  $committed_file — '$line' is not a valid provider name (want lowercase [a-z0-9-], no leading/trailing '-')")
      malformed=1
    fi
  done <"$committed_file"

  if [[ "$malformed" -eq 0 ]]; then
    committed_list="$(pa_committed_list)"
    if ! printf '%s\n' "$committed_list" | grep -Fx "$TRUSTED_DEFAULT_PROVIDER" >/dev/null; then
      failures+=("ANTHROPIC-MISSING  $committed_file — the committed allowlist no longer names the trusted default provider '$TRUSTED_DEFAULT_PROVIDER' (ADR 0028 decision 3)")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. No-widen: a personal override may only narrow.
# ---------------------------------------------------------------------------
local_file="$(pa_local_file)"
if [[ -f "$local_file" && ! -r "$local_file" ]]; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — the personal narrowing override ($local_file) exists but is not readable; aborting rather than reporting a pass on an override this gate could not read" >&2
  exit 1
fi
if [[ -f "$local_file" ]]; then
  # `|| true`: pa_narrowing_violations returns 1 as its normal "found some"
  # verdict, and this script's own `set -uo pipefail` leaves that unguarded
  # assignment's rc unchecked — spelled out so a later `set -e` addition
  # cannot silently turn a real widen attempt into an early exit.
  widen="$(pa_narrowing_violations)" || true
  if [[ -n "$widen" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      failures+=("WIDEN-REJECTED  $local_file names '$p', which is not in the committed ceiling ($committed_file) — a personal override may only narrow, never widen")
    done <<<"$widen"
  fi
fi

# ---------------------------------------------------------------------------
# 3 + 4. Disclosure log: format/chain validity, then allowlist membership.
#    Absent or empty log is LEGAL (a checkout that never ran a comparison).
# ---------------------------------------------------------------------------
log_file="$(pa_disclosure_log_file)"
n_entries=0

if [[ -e "$log_file" && ! -r "$log_file" ]]; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — the disclosure log ($log_file) exists but is not readable; aborting rather than reporting a pass on a log this gate could not read" >&2
  exit 1
fi

# ALWAYS run the chain check, including on an absent/empty log: the watermark
# anchor lives beside the log, so "log deleted, anchor still records three
# entries" is exactly the case a `[[ -f ]]` guard around this block used to
# skip. pa_verify_log_chain itself owns the "absent log with no anchor is
# legal" rule.
chain_out=""
chain_rc=0
chain_out="$(pa_verify_log_chain "$log_file")" || chain_rc=$?
if [[ "$chain_rc" -eq "$PA_RC_CANNOT_EVALUATE" ]]; then
  echo "validate-provider-disclosure: CANNOT EVALUATE the disclosure log ($log_file) — aborting rather than reporting a false pass/fail" >&2
  echo "$chain_out" >&2
  exit 1
elif [[ "$chain_rc" -ne 0 ]]; then
  # A non-zero rc with NO violation lines is not a clean log — it is a
  # verdict we could not compute (the shape an unreadable-file redirect
  # produced: loop body never ran, rc non-zero, stdout empty). Treating it as
  # "nothing to append to failures" is the fail-OPEN this gate must not do.
  if [[ -z "${chain_out//[$'\n\t ']/}" ]]; then
    echo "validate-provider-disclosure: CANNOT EVALUATE the disclosure log ($log_file) — the chain verifier returned rc=$chain_rc but reported no violations, which is not a verdict; aborting rather than treating it as clean" >&2
    exit 1
  fi
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    failures+=("$v")
  done <<<"$chain_out"
fi

if [[ -f "$log_file" && -s "$log_file" ]]; then
  # Membership check runs independently of chain-validity, best-effort per
  # line (a line whose JSON parses fine but whose chain is broken can still
  # be checked for membership) — a malformed line (caught above) is simply
  # skipped here since it has no reliable `.provider` to check.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    n_entries=$((n_entries + 1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      continue
    fi
    provider="$(printf '%s' "$line" | jq -r '.provider // empty' 2>/dev/null)"
    [[ -z "$provider" ]] && continue
    if ! pa_is_allowed "$provider" 2>/dev/null; then
      failures+=("ALLOWLIST-VIOLATION  $log_file — entry names provider '$provider', which is not in the current effective allowlist")
    fi
  done <"$log_file"
fi

# ---------------------------------------------------------------------------
# 5. SEND-VS-LOG coverage: every non-default-provider SEND has a matching
#    disclosure entry. (temperloop#1258 — the half #1250 deferred.)
# ---------------------------------------------------------------------------
send_lake_dir="${MODEL_USAGE_RAW_DIR:-$repo_root_for_git/meta/data/raw}"
n_sends=0
n_nondefault_sends=0

# The join key set, built ONCE from the disclosure log: one
# "<provider>\t<item_ref>" line per entry. Built from the log this script
# already read above via the allowlist library's own path accessor — no
# second notion of where the log lives.
disclosed_pairs=""
if [[ -f "$log_file" && -s "$log_file" && -r "$log_file" ]]; then
  disclosed_pairs="$(jq -r 'select(type == "object")
                            | select((.provider // "") != "" and (.item_ref // "") != "")
                            | .provider + "\t" + .item_ref' "$log_file" 2>/dev/null)"
fi

if [[ -e "$send_lake_dir" ]]; then
  if [[ ! -d "$send_lake_dir" ]]; then
    echo "validate-provider-disclosure: CANNOT EVALUATE — the attribution raw-lake path ($send_lake_dir) exists but is not a directory; aborting rather than reporting a pass on a send stream this gate could not enumerate" >&2
    exit 1
  fi
  if [[ ! -r "$send_lake_dir" || ! -x "$send_lake_dir" ]]; then
    echo "validate-provider-disclosure: CANNOT EVALUATE — the attribution raw-lake dir ($send_lake_dir) is not readable; aborting rather than reporting a pass on sends this gate could not read" >&2
    exit 1
  fi
  for send_file in "$send_lake_dir"/model-usage-*.jsonl; do
    [[ -e "$send_file" ]] || continue
    if [[ ! -f "$send_file" || ! -r "$send_file" ]]; then
      echo "validate-provider-disclosure: CANNOT EVALUATE — the attribution stream file ($send_file) is not a readable regular file; aborting rather than reporting a pass on sends this gate could not read" >&2
      exit 1
    fi
    while IFS= read -r sline || [[ -n "$sline" ]]; do
      [[ -z "$sline" ]] && continue
      # A line this gate cannot parse is a line whose provider it cannot
      # determine — so it cannot tell an undisclosed non-default send from a
      # benign default-provider one. Fail-closed, never skip: skipping is
      # exactly how an unreadable input reads as clean.
      if ! printf '%s' "$sline" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "validate-provider-disclosure: CANNOT EVALUATE — $send_file carries a line that is not a JSON object, so this gate cannot tell whether it records a non-default-provider send; aborting rather than trusting a partial scan" >&2
        exit 1
      fi
      n_sends=$((n_sends + 1))
      send_provider="$(printf '%s' "$sline" | jq -r '.provider // empty' 2>/dev/null)"
      # No provider recorded (an attribution-only record, usage_source
      # "unavailable" — emit-model-usage.sh forbids a provider there) is not
      # evidence of a non-default send; it carries no provider to check.
      [[ -z "$send_provider" || "$send_provider" == "null" ]] && continue
      [[ "$send_provider" == "$TRUSTED_DEFAULT_PROVIDER" ]] && continue
      n_nondefault_sends=$((n_nondefault_sends + 1))

      send_ref="$(printf '%s' "$sline" | jq -r '.outcome_ref // empty' 2>/dev/null)"
      if [[ -z "$send_ref" ]]; then
        failures+=("SEND-UNREFERENCED  $send_file — a send to non-default provider '$send_provider' carries no outcome_ref, so it cannot be cross-referenced against any disclosure-log entry")
        continue
      fi
      if ! printf '%s\n' "$disclosed_pairs" | grep -Fx "$send_provider	$send_ref" >/dev/null 2>&1; then
        failures+=("SEND-WITHOUT-DISCLOSURE  $send_file — a send to non-default provider '$send_provider' for '$send_ref' has NO matching entry in the disclosure log ($log_file); every non-default-provider send must be disclosed (ADR 0028 decision 2)")
      fi
    done <"$send_file"
  done
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "Checked committed allowlist ($committed_file)$( [[ -f "$local_file" ]] && printf ', personal override (%s)' "$local_file" ), disclosure log ($log_file, $n_entries entr$( [[ "$n_entries" -eq 1 ]] && echo y || echo ies )), attribution sends ($send_lake_dir, $n_sends record$( [[ "$n_sends" -eq 1 ]] || echo s ), $n_nondefault_sends non-default-provider)"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "validate-provider-disclosure: FAIL"
  exit 1
fi
echo "validate-provider-disclosure: OK"
