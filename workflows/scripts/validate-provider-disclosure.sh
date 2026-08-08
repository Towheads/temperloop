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
#      literal "genesis" for the first entry). This is what makes "an entry
#      cannot be rewritten or removed in place" a MECHANICALLY CHECKED
#      property — a tampered entry breaks the chain and fails this gate.
#   4. DISCLOSURE-LOG MEMBERSHIP checks — every logged entry's provider is
#      in the CURRENT effective allowlist (committed narrowed by any
#      personal override). A logged provider that the allowlist no longer
#      (or never did) allow is a violation.
#
# EXPLICITLY OUT OF SCOPE (owned by a LATER item, replay-execute-and-score):
# the send-vs-log COVERAGE cross-check — proving that every actual send to
# a non-default provider produced a matching log entry. That needs a
# `provider` field on an attribution record which does not exist until the
# attribution-emit-family item lands. Its absence must NOT, and does NOT,
# fail this gate.
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
# pass.
#
# Usage:
#   workflows/scripts/validate-provider-disclosure.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (test seam — same names allowlist.sh itself reads, so a
# fixture repo just points all three at a scratch dir):
#   PROVIDER_ALLOWLIST_COMMITTED_FILE
#   PROVIDER_ALLOWLIST_LOCAL_FILE
#   PROVIDER_DISCLOSURE_LOG_FILE
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
# shellcheck source=workflows/scripts/model-comparison/allowlist.sh
source "$ALLOWLIST_LIB"

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-provider-disclosure: CANNOT EVALUATE — jq not found" >&2
  exit 1
fi

failures=()
TRUSTED_DEFAULT_PROVIDER="anthropic"

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
else
  # Must be a real git-tracked path, not merely present on disk (a fresh
  # `touch` would satisfy -f but carries no review/commit history). Only
  # meaningful for a file actually inside this repo checkout — a test
  # fixture deliberately points PROVIDER_ALLOWLIST_COMMITTED_FILE at a
  # scratch path outside the repo (to exercise narrowing/disclosure-log
  # behavior in isolation), where "git-tracked" has no meaning to check.
  repo_root_for_git="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
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
if [[ -f "$local_file" ]]; then
  widen="$(pa_narrowing_violations)"
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
if [[ -f "$log_file" && -s "$log_file" ]]; then
  chain_out=""
  chain_rc=0
  chain_out="$(pa_verify_log_chain "$log_file")" || chain_rc=$?
  if [[ "$chain_rc" -eq "$PA_RC_CANNOT_EVALUATE" ]]; then
    echo "validate-provider-disclosure: CANNOT EVALUATE the disclosure log ($log_file) — aborting rather than reporting a false pass/fail" >&2
    echo "$chain_out" >&2
    exit 1
  elif [[ "$chain_rc" -ne 0 ]]; then
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      failures+=("$v")
    done <<<"$chain_out"
  fi

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
# Verdict.
# ---------------------------------------------------------------------------
echo "Checked committed allowlist ($committed_file)$( [[ -f "$local_file" ]] && printf ', personal override (%s)' "$local_file" ), disclosure log ($log_file, $n_entries entr$( [[ "$n_entries" -eq 1 ]] && echo y || echo ies ))"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "validate-provider-disclosure: FAIL"
  exit 1
fi
echo "validate-provider-disclosure: OK"
