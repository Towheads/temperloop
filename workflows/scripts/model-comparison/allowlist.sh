#!/usr/bin/env bash
#
# allowlist.sh — provider allowlist resolution + the paired append-only
# disclosure log (temperloop#1250, epic #1225, ADR 0028 decisions 1 and 2:
# docs/adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md).
#
# SOURCED LIBRARY, not a standalone script — like
# workflows/scripts/config/setting-registry-lib.sh, this file defines
# functions only and never sets shell options (`set -e`/`pipefail`) at
# source time, so sourcing it never mutates the caller's shell. A caller
# that runs this file directly (`bash allowlist.sh <subcommand> ...`) gets a
# tiny CLI dispatcher at the bottom, guarded so it never fires under
# `source`.
#
# ── The two artifacts, and why they live in different trust tiers ──────────
#
# 1. COMMITTED ALLOWLIST (pa_committed_file) — a git-tracked file under this
#    module's own subtree, default Anthropic-only. This is the CEILING: the
#    one and only place a new provider is added, and it happens through a
#    reviewed commit like any other change — never an env var, never a
#    `$HOME` config, never anything under the gitignored `.temperloop/`
#    runtime dir. A personal override (below) can narrow this set; nothing
#    can widen it outside a reviewed commit to this file.
#
# 2. PERSONAL NARROWING OVERRIDE (pa_local_file) — an OPTIONAL, untracked,
#    repo-scoped file under `.temperloop/model-comparison/` (see
#    allowlist.local.txt.example beside this script for the format). It may
#    remove providers from the effective set; it may never add one the
#    committed file doesn't already list. An attempt to widen is a hard
#    failure (pa_narrowing_violations / pa_effective_list both refuse to
#    resolve, fail-closed) rather than a silently-ignored no-op — a broken
#    or tampered personal override must never quietly grant more access
#    than the committed ceiling.
#
# The EFFECTIVE allowlist (pa_effective_list / pa_is_allowed) is the
# committed set narrowed by the personal override when one is present.
#
# ── The disclosure log (pa_disclose / pa_verify_log_chain) ─────────────────
#
# Every send to a non-default provider gets exactly one append-only JSONL
# entry: schema_version, ts (ISO-8601 UTC), provider, item_ref, seq,
# prev_hash, hash — NEVER content. Entries are chained: each entry's `hash`
# covers its own fields, and the next entry's `prev_hash` must equal it (the
# first entry's prev_hash is the literal "genesis"). This is what makes "an
# entry cannot be rewritten or removed in place" a MECHANICALLY CHECKED
# property rather than a promise: pa_verify_log_chain recomputes every
# hash and every link, so an edited field or a deleted line breaks the chain
# and is caught by workflows/scripts/validate-provider-disclosure.sh, the
# validator that sources this file. pa_disclose is the ONLY writer this
# library exposes — there is no update/delete function — and it refuses to
# write an entry for a provider the effective allowlist doesn't currently
# allow (the allowlist and the log are paired mechanically, ADR 0028
# decision 2, not by convention).
#
# GATE SCOPE (temperloop#1250): this file (and its validator) own
# ALLOWLIST NARROWING and DISCLOSURE-LOG FORMAT/CHAIN/MEMBERSHIP only. The
# send-vs-log COVERAGE cross-check — proving a non-default-provider send
# actually produced a log entry — needs a `provider` field on an
# attribution record that does not exist yet (owned by the later
# replay-execute-and-score item) and is deliberately NOT implemented here.
#
# Env overrides (test seam, same shape as FEATURE_DOCS_ROOT/etc. in
# workflows/scripts/validate-feature-docs.sh):
#   PROVIDER_ALLOWLIST_COMMITTED_FILE   default: this dir's provider-allowlist.txt
#   PROVIDER_ALLOWLIST_LOCAL_FILE       default: <repo>/.temperloop/model-comparison/allowlist.local.txt
#   PROVIDER_DISCLOSURE_LOG_FILE        default: <repo>/.temperloop/model-comparison/disclosure-log.jsonl
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, per this repo's usual convention.

_PA_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PA_REPO_ROOT="$(cd -P "$_PA_SCRIPT_DIR/../../.." && pwd)"

: "${PROVIDER_ALLOWLIST_COMMITTED_FILE:=$_PA_SCRIPT_DIR/provider-allowlist.txt}"
: "${PROVIDER_ALLOWLIST_LOCAL_FILE:=$_PA_REPO_ROOT/.temperloop/model-comparison/allowlist.local.txt}"
: "${PROVIDER_DISCLOSURE_LOG_FILE:=$_PA_REPO_ROOT/.temperloop/model-comparison/disclosure-log.jsonl}"

# Kernel built-in default (layer 6, docs/config-precedence.md) — used only
# if the committed file is somehow absent/unreadable/empty, so a broken
# checkout still fails safely CLOSED to "Anthropic only" rather than open to
# "everything".
_PA_BUILTIN_DEFAULT="anthropic"

pa_committed_file() { printf '%s\n' "$PROVIDER_ALLOWLIST_COMMITTED_FILE"; }
pa_local_file() { printf '%s\n' "$PROVIDER_ALLOWLIST_LOCAL_FILE"; }
pa_disclosure_log_file() { printf '%s\n' "$PROVIDER_DISCLOSURE_LOG_FILE"; }

# pa_valid_provider_name <name> — rc 0 iff it matches the same
# [a-z0-9-]-no-leading/trailing-hyphen slug shape validate-feature-docs.sh
# uses for feature slugs.
pa_valid_provider_name() {
  case "$1" in
    '') return 1 ;;
    *[!a-z0-9-]* | -* | *-) return 1 ;;
    *) return 0 ;;
  esac
}

# _pa_parse_file <path> — one normalized (lowercased, trimmed) provider name
# per output line, `#`-comments and blank lines stripped, sorted+deduped.
# Prints nothing (rc 0) if the file does not exist — "no file" and "empty
# file" are deliberately the same observable shape here; callers that need
# to tell "no override" from "override narrows to nothing" use
# pa_local_file's -f test directly (see pa_local_list).
_pa_parse_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    { sub(/#.*/, "") }
    { gsub(/^[ \t]+|[ \t]+$/, "") }
    { print tolower($0) }
  ' "$f" | grep -v '^$' | sort -u
}

# pa_committed_list — the committed ceiling, normalized. Falls back to the
# hardcoded built-in default (fail CLOSED to Anthropic-only, never open) if
# the committed file is missing or yields zero entries, with a loud stderr
# warning — a real checkout ships the file, so this path means something is
# wrong with the checkout, not a legitimate empty-ceiling state.
pa_committed_list() {
  local f out
  f="$(pa_committed_file)"
  out="$(_pa_parse_file "$f")"
  if [[ -z "$out" ]]; then
    echo "allowlist.sh: WARN committed provider allowlist ($f) is missing or empty — falling back to the built-in default '$_PA_BUILTIN_DEFAULT'" >&2
    out="$_PA_BUILTIN_DEFAULT"
  fi
  printf '%s\n' "$out"
}

# pa_local_list — rc 0 + the (possibly empty) narrowed list on stdout if a
# personal override file EXISTS; rc 1 + no output if it does not (no
# override in effect). This distinction matters: an existing-but-empty
# override legitimately narrows the effective set to nothing.
pa_local_list() {
  local f
  f="$(pa_local_file)"
  [[ -f "$f" ]] || return 1
  _pa_parse_file "$f"
  return 0
}

# pa_narrowing_violations — prints any provider present in the personal
# override that is NOT in the committed ceiling (one per line) and returns
# rc 1 if any were found. rc 0 + no output if there is no override, or the
# override is a legal subset (or exact match) of the committed list.
pa_narrowing_violations() {
  local committed local_list found=0
  committed="$(pa_committed_list)"
  local_list="$(pa_local_list)" || return 0   # no override — nothing to violate
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if ! printf '%s\n' "$committed" | grep -Fx "$p" >/dev/null; then
      printf '%s\n' "$p"
      found=1
    fi
  done <<<"$local_list"
  [[ "$found" -eq 0 ]]
}

# pa_effective_list — the committed ceiling narrowed by the personal
# override, if any. FAILS CLOSED (rc 2, no stdout) when the override
# attempts to widen — callers must never treat a failed call's absent
# output as "nothing allowed"; they must check rc.
#   rc 0   effective list on stdout (possibly the full committed list)
#   rc 2   the personal override attempts to widen — refused; see stderr
PA_RC_WIDEN_REJECTED=2
pa_effective_list() {
  local violations
  if [[ -f "$(pa_local_file)" ]]; then
    violations="$(pa_narrowing_violations)"
    if [[ -n "$violations" ]]; then
      echo "allowlist.sh: REJECTED — personal override ($(pa_local_file)) attempts to WIDEN the committed allowlist ($(pa_committed_file)) with: $(printf '%s' "$violations" | tr '\n' ' ')— a personal config may only narrow, never widen (ADR 0028 decision 1). Refusing to resolve an effective allowlist." >&2
      return "$PA_RC_WIDEN_REJECTED"
    fi
    pa_local_list
    return 0
  fi
  pa_committed_list
}

# pa_is_allowed <provider> — rc 0 iff <provider> is in the effective
# allowlist. Fails CLOSED (denies) on any resolution error, including a
# widen-attempt in the personal override — a broken config denies
# everything rather than silently falling back to "everything the
# committed file allows".
pa_is_allowed() {
  local provider="$1" effective
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
  effective="$(pa_effective_list)" || {
    echo "allowlist.sh: DENY '$provider' — provider allowlist configuration is invalid (see above); denying by default (fail closed)" >&2
    return 1
  }
  printf '%s\n' "$effective" | grep -Fx "$provider" >/dev/null
}

# ---------------------------------------------------------------------------
# The disclosure log: append-only, hash-chained.
# ---------------------------------------------------------------------------

# _pa_sha256 <string> — portable sha256 (sha256sum preferred, shasum -a 256
# fallback — same idiom as workflows/scripts/chunk-redundancy-surface.sh's
# _crs_sha256 / workflows/scripts/lib/gate-retry.sh). Hashes the argument
# EXACTLY as given (printf '%s', no trailing newline) so the hash is
# reproducible across environments.
_pa_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

PA_DISCLOSURE_SCHEMA_VERSION="1"
PA_DISCLOSURE_GENESIS="genesis"
# The fixed field set every disclosure-log entry MUST have, exactly (no
# more, no fewer) — enforced by pa_verify_log_chain so a future caller can
# never accidentally (or otherwise) grow the record to carry content.
PA_DISCLOSURE_FIELDS='hash item_ref prev_hash provider schema_version seq ts'

# _pa_canonical_entry schema_version ts provider item_ref seq prev_hash
# — the exact pipe-joined string pa_disclose hashes into `hash`, and that
# pa_verify_log_chain recomputes to check it. A dedicated function so the
# two call sites can never drift out of sync with each other.
_pa_canonical_entry() {
  printf '%s|%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5" "$6"
}

# pa_disclose <provider> <item_ref> — append ONE entry to the disclosure
# log for a send to a non-default provider. Refuses (rc 1, no line written)
# if <provider> is not currently in the effective allowlist — the log and
# the allowlist are paired mechanically, never by convention (ADR 0028
# decision 2). Never logs content: only provider, item_ref, and timestamp.
pa_disclose() {
  local provider="$1" item_ref="$2" log ts seq prev_hash canonical hash record
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$provider" || -z "$item_ref" ]]; then
    echo "allowlist.sh: pa_disclose requires a non-empty provider and item_ref — no entry written" >&2
    return 1
  fi
  case "$item_ref" in
    *$'\n'*)
      echo "allowlist.sh: pa_disclose: item_ref must not contain a newline — no entry written" >&2
      return 1
      ;;
  esac
  if ! pa_is_allowed "$provider"; then
    echo "allowlist.sh: pa_disclose REFUSED — '$provider' is not in the current effective allowlist; a disclosure entry is only ever written for an allowed provider (ADR 0028 decision 2 pairing) — no entry written" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "allowlist.sh: pa_disclose: jq not found — no entry written" >&2
    return 1
  fi

  log="$(pa_disclosure_log_file)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -f "$log" && -s "$log" ]]; then
    seq=$(($(grep -c . "$log" 2>/dev/null || echo 0) + 1))
    prev_hash="$(tail -n 1 "$log" | jq -r '.hash // empty' 2>/dev/null)"
    if [[ -z "$prev_hash" ]]; then
      echo "allowlist.sh: pa_disclose: existing log ($log) has an unreadable last line — refusing to append onto a chain we cannot extend safely" >&2
      return 1
    fi
  else
    seq=1
    prev_hash="$PA_DISCLOSURE_GENESIS"
  fi

  canonical="$(_pa_canonical_entry "$PA_DISCLOSURE_SCHEMA_VERSION" "$ts" "$provider" "$item_ref" "$seq" "$prev_hash")"
  hash="$(_pa_sha256 "$canonical")"

  record="$(jq -nc \
    --arg schema_version "$PA_DISCLOSURE_SCHEMA_VERSION" \
    --arg ts "$ts" \
    --arg provider "$provider" \
    --arg item_ref "$item_ref" \
    --argjson seq "$seq" \
    --arg prev_hash "$prev_hash" \
    --arg hash "$hash" \
    '{schema_version: $schema_version, ts: $ts, provider: $provider, item_ref: $item_ref, seq: $seq, prev_hash: $prev_hash, hash: $hash}' 2>/dev/null)"
  if [[ -z "$record" ]]; then
    echo "allowlist.sh: pa_disclose: failed to build the JSON record — no entry written" >&2
    return 1
  fi

  printf '%s\n' "$record" >>"$log"
}

# pa_verify_log_chain <logfile> — format + hash-chain validity ONLY (no
# allowlist-membership check; the validator does that separately so this
# function stays reusable by anything that just wants "is this log
# internally consistent"). Missing/empty file is legal (rc 0, no output) —
# a fresh checkout that never ran a comparison has no log yet.
#   rc 0   clean (violations array empty)
#   rc 1   one or more violations (printed, one per line)
#   rc 2   CANNOT EVALUATE (e.g. jq missing) — never silently reports clean
PA_RC_CHAIN_VIOLATIONS=1
PA_RC_CANNOT_EVALUATE=2
pa_verify_log_chain() {
  local log="$1" lineno=0 expect_seq=1 expect_prev="$PA_DISCLOSURE_GENESIS"
  local line keys schema_version ts provider item_ref seq prev_hash hash canonical recomputed
  local violations=0

  [[ -f "$log" ]] || return 0
  [[ -s "$log" ]] || return 0

  if ! command -v jq >/dev/null 2>&1; then
    echo "CANNOT-EVALUATE  jq not found — cannot verify $log" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" ]] && continue

    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      echo "MALFORMED-JSON  $log:$lineno — line is not valid JSON"
      violations=$((violations + 1))
      continue
    fi

    keys="$(printf '%s' "$line" | jq -r 'keys | sort | join(" ")' 2>/dev/null)"
    if [[ "$keys" != "$PA_DISCLOSURE_FIELDS" ]]; then
      echo "FIELD-SET  $log:$lineno — field set '$keys' != expected '$PA_DISCLOSURE_FIELDS' (never carries content beyond provider/item_ref/timestamp)"
      violations=$((violations + 1))
      continue
    fi

    schema_version="$(printf '%s' "$line" | jq -r '.schema_version')"
    ts="$(printf '%s' "$line" | jq -r '.ts')"
    provider="$(printf '%s' "$line" | jq -r '.provider')"
    item_ref="$(printf '%s' "$line" | jq -r '.item_ref')"
    seq="$(printf '%s' "$line" | jq -r '.seq')"
    prev_hash="$(printf '%s' "$line" | jq -r '.prev_hash')"
    hash="$(printf '%s' "$line" | jq -r '.hash')"

    if [[ "$seq" != "$expect_seq" ]]; then
      echo "SEQ-GAP  $log:$lineno — seq=$seq, expected $expect_seq (a removed or reordered entry breaks the sequence)"
      violations=$((violations + 1))
    fi
    if [[ "$prev_hash" != "$expect_prev" ]]; then
      echo "BROKEN-CHAIN  $log:$lineno — prev_hash='$prev_hash' does not match the preceding entry's hash '$expect_prev' (an entry was rewritten or removed)"
      violations=$((violations + 1))
    fi

    canonical="$(_pa_canonical_entry "$schema_version" "$ts" "$provider" "$item_ref" "$seq" "$prev_hash")"
    recomputed="$(_pa_sha256 "$canonical")"
    if [[ "$hash" != "$recomputed" ]]; then
      echo "INVALID-HASH  $log:$lineno — stored hash does not match its own fields (the entry was rewritten in place)"
      violations=$((violations + 1))
    fi

    expect_seq=$((seq + 1))
    expect_prev="$hash"
  done <"$log"

  [[ "$violations" -eq 0 ]] || return "$PA_RC_CHAIN_VIOLATIONS"
  return 0
}

# ---------------------------------------------------------------------------
# Tiny CLI dispatcher — only fires when this file is EXECUTED, never when
# sourced (test_allowlist.sh and validate-provider-disclosure.sh source
# this file directly to call the functions above).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    is-allowed)
      pa_is_allowed "${2:-}"
      ;;
    committed)
      pa_committed_list
      ;;
    effective)
      pa_effective_list
      ;;
    disclose)
      pa_disclose "${2:-}" "${3:-}"
      ;;
    verify-log)
      pa_verify_log_chain "${2:-$(pa_disclosure_log_file)}"
      ;;
    *)
      echo "usage: allowlist.sh {is-allowed <provider>|committed|effective|disclose <provider> <item_ref>|verify-log [file]}" >&2
      exit 64
      ;;
  esac
fi
