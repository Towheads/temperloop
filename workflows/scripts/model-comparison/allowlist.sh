#!/usr/bin/env bash
#
# allowlist.sh — provider allowlist resolution + the paired append-only
# disclosure log (temperloop#1250, epic #1225, ADR 0028 decisions 1 and 2:
# docs/adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md).
#
# SOURCED LIBRARY, not a standalone script — like
# workflows/scripts/config/setting-registry-lib.sh, this file defines
# functions only and never sets shell options (`set -e`/`pipefail`) at
# source time, so sourcing it never mutates the caller's shell. It is also
# safe to source INTO a `set -euo pipefail` caller: every pipeline here is
# pipefail-proof (no `| grep` filter that legitimately matches nothing) and
# every function that returns non-zero as a normal verdict is called through
# a guarded form internally. A caller that runs this file directly (`bash
# allowlist.sh <subcommand> ...`) gets a tiny CLI dispatcher at the bottom,
# guarded so it never fires under `source`.
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
#    The three path env vars named under "Env overrides" below are a
#    FIXTURE-TEST SEAM, not a configuration surface: they are read ONLY when
#    PROVIDER_ALLOWLIST_TEST_SEAM=1 is also set, and are otherwise ignored
#    (with a loud stderr notice) in favour of the committed defaults. Without
#    that guard, `PROVIDER_ALLOWLIST_COMMITTED_FILE=/tmp/widened.txt` would
#    repoint the ceiling from the environment — exactly the "never an env
#    var" property ADR 0028 decision 1 requires. validate-provider-disclosure.sh
#    hard-fails if a non-default committed-file override is present without
#    the seam flag, so the gate cannot be pointed at a friendlier ceiling.
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
# committed set narrowed by the personal override when one is present. Both
# the name being CHECKED and every name in either file must be a well-formed
# provider slug (pa_valid_provider_name): a malformed name — most sharply a
# MULTI-LINE one — is denied outright rather than compared. A multi-line
# name against a line-oriented membership test is a real bypass, not a
# hypothetical one: `printf '%s\n' "$set" | grep -Fx "$name"` treats a
# multi-line `$name` as MULTIPLE patterns and matches if ANY line is allowed,
# and `grep -Fx ""` matches the empty line an empty set prints. Membership is
# therefore an explicit line-by-line string comparison here, never a grep.
#
# ── The disclosure log (pa_disclose / pa_verify_log_chain) ─────────────────
#
# Every send to a non-default provider gets exactly one append-only JSONL
# entry: schema_version, ts (ISO-8601 UTC), provider, item_ref, seq,
# prev_hash, hash — NEVER content. Entries are chained: each entry's `hash`
# covers its own fields, and the next entry's `prev_hash` must equal it (the
# first entry's prev_hash is the literal "genesis"). pa_disclose is the ONLY
# writer this library exposes — there is no update/delete function — and it
# refuses to write an entry for a provider the effective allowlist doesn't
# currently allow (the allowlist and the log are paired mechanically, ADR
# 0028 decision 2, not by convention). Concurrent discloses are serialized by
# a lock directory beside the log, so a fan-out over several providers cannot
# interleave two read-modify-append cycles into a permanently broken chain.
#
# ── WHAT THE CHAIN ACTUALLY PROVES (read this before trusting the log) ─────
#
# The hash chain is a TAMPER-EVIDENCE mechanism with a stated, bounded reach.
# It DETECTS, mechanically:
#   * an entry rewritten in place (its stored `hash` stops matching its own
#     fields — INVALID-HASH);
#   * an entry deleted or reordered in the INTERIOR of an otherwise intact
#     file (the following entry's `prev_hash` and `seq` stop lining up —
#     BROKEN-CHAIN / SEQ-GAP);
#   * an entry grown to carry content or any other extra field (FIELD-SET).
#
# It does NOT, and cannot, detect on its own:
#   * TRUNCATION of the log's tail — an unanchored chain records nothing
#     about how long it is meant to be, so `head -n -1` leaves a perfectly
#     valid shorter chain;
#   * DELETION of the whole log — an absent log is legal by construction (a
#     fresh checkout has never sent anything);
#   * a full RE-FORGE — the chain is unkeyed, so anyone who can write the log
#     can rebuild every entry and every hash from scratch and produce a
#     chain that verifies clean.
#
# WATERMARK ANCHOR (defence in depth, not a proof). pa_disclose maintains a
# `disclosure-log.watermark` file holding `<max_seq> <last_hash>`, written
# inside the same lock as the append. pa_verify_log_chain compares the log's
# tail against it, so truncation below the watermark (TRUNCATED), a re-forge
# that changes the tail hash (REFORGED), an append that bypassed pa_disclose
# (WATERMARK-STALE), and a non-empty log with the anchor deleted
# (WATERMARK-MISSING) all fail.
#
# THE ANCHOR IS COMMITTED; THE LOG IS NOT (temperloop#1316). The anchor no
# longer sits beside the log in the gitignored runtime dir — it lives in the
# TRACKED tree at workflows/scripts/model-comparison/disclosure-log.watermark,
# beside the committed provider allowlist, while the log itself stays
# gitignored at .temperloop/model-comparison/disclosure-log.jsonl so no
# provider history and no content ever enters the repo. The anchor carries
# neither: it is two values' worth of state (how many entries the log is
# meant to have, and its tail hash).
#
# WHAT THAT BUYS, stated precisely. The anchor used to live in the SAME
# gitignored directory as the log, so whoever could rewrite the log could
# rewrite its anchor in the same motion and a full re-forge verified clean.
# Now pa_verify_watermark_git_anchor additionally checks the log against the
# anchor AS COMMITTED IN GIT (HEAD's blob), so a re-forge must ALSO rewrite
# git history to stay hidden — which leaves its own trace. The threat this
# closes is NOT an external attacker (local write access makes everything
# theirs anyway) but a careless or self-serving LOCAL PROCESS: an agent or
# script regenerating state, or an operator tidying a log before review.
# Signing entries and shipping to an external append-only sink were both
# considered and REJECTED as overbuilt for that threat — no key management
# story, and no second home for provider history.
#
# GATE SCOPE (temperloop#1250): this file (and its validator) own
# ALLOWLIST NARROWING and DISCLOSURE-LOG FORMAT/CHAIN/MEMBERSHIP only. The
# send-vs-log COVERAGE cross-check — proving a non-default-provider send
# actually produced a log entry — needs a `provider` field on an
# attribution record that does not exist yet (owned by the later
# replay-execute-and-score item) and is deliberately NOT implemented here.
#
# Env overrides (FIXTURE-TEST SEAM — read only when PROVIDER_ALLOWLIST_TEST_SEAM=1;
# same shape as FEATURE_DOCS_ROOT/etc. in workflows/scripts/validate-feature-docs.sh):
#   PROVIDER_ALLOWLIST_COMMITTED_FILE   default: this dir's provider-allowlist.txt
#   PROVIDER_ALLOWLIST_LOCAL_FILE       default: <repo>/.temperloop/model-comparison/allowlist.local.txt
#   PROVIDER_DISCLOSURE_LOG_FILE        default: <repo>/.temperloop/model-comparison/disclosure-log.jsonl
#   PROVIDER_DISCLOSURE_WATERMARK_FILE  default: this dir's disclosure-log.watermark
#                                       (UNDER THE SEAM ONLY, the sibling of
#                                       whatever log the seam points at — see
#                                       the seam block below for why)
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, per this repo's usual convention.

_PA_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PA_REPO_ROOT="$(cd -P "$_PA_SCRIPT_DIR/../../.." && pwd)"

# The four path seams are honoured ONLY under an explicit test-seam flag —
# see "1. COMMITTED ALLOWLIST" above. Outside it the committed defaults are
# ASSIGNED unconditionally, so an inherited environment cannot repoint the
# ceiling, the personal override, the log, or the committed anchor.
#
# THE WATERMARK SEAM'S DEFAULT DELIBERATELY DIFFERS BETWEEN THE TWO BRANCHES.
# In production the anchor is the TRACKED file beside the committed allowlist
# (temperloop#1316) — never the log's gitignored sibling, which is the whole
# point of moving it. Under the fixture seam it defaults to the sibling of
# whatever scratch log the seam points at, so a fixture that repoints only
# PROVIDER_DISCLOSURE_LOG_FILE (every pre-#1316 fixture site does) is
# STRUCTURALLY unable to read — or, worse, overwrite — the repo's real
# committed anchor. A fixture that wants to exercise the committed-anchor
# behaviour points this seam at its own synthesized git repo explicitly.
if [[ "${PROVIDER_ALLOWLIST_TEST_SEAM:-0}" == "1" ]]; then
  : "${PROVIDER_ALLOWLIST_COMMITTED_FILE:=$_PA_SCRIPT_DIR/provider-allowlist.txt}"
  : "${PROVIDER_ALLOWLIST_LOCAL_FILE:=$_PA_REPO_ROOT/.temperloop/model-comparison/allowlist.local.txt}"
  : "${PROVIDER_DISCLOSURE_LOG_FILE:=$_PA_REPO_ROOT/.temperloop/model-comparison/disclosure-log.jsonl}"
  # Nested-expansion-free so the setting-registry equality lint sees a flat
  # literal in the `:=` seam (workflows/scripts/config/check-setting-registry.sh).
  _PA_SEAM_SIBLING_WATERMARK="${PROVIDER_DISCLOSURE_LOG_FILE%.jsonl}.watermark"
  : "${PROVIDER_DISCLOSURE_WATERMARK_FILE:=$_PA_SEAM_SIBLING_WATERMARK}"
else
  if [[ -n "${PROVIDER_ALLOWLIST_COMMITTED_FILE+x}" || -n "${PROVIDER_ALLOWLIST_LOCAL_FILE+x}" \
        || -n "${PROVIDER_DISCLOSURE_LOG_FILE+x}" || -n "${PROVIDER_DISCLOSURE_WATERMARK_FILE+x}" ]]; then
    echo "allowlist.sh: IGNORING the PROVIDER_ALLOWLIST_*/PROVIDER_DISCLOSURE_* path overrides — they are a fixture-test seam that requires PROVIDER_ALLOWLIST_TEST_SEAM=1. The committed ceiling is never repointed from the environment (ADR 0028 decision 1)." >&2
  fi
  PROVIDER_ALLOWLIST_COMMITTED_FILE="$_PA_SCRIPT_DIR/provider-allowlist.txt"
  PROVIDER_ALLOWLIST_LOCAL_FILE="$_PA_REPO_ROOT/.temperloop/model-comparison/allowlist.local.txt"
  PROVIDER_DISCLOSURE_LOG_FILE="$_PA_REPO_ROOT/.temperloop/model-comparison/disclosure-log.jsonl"
  PROVIDER_DISCLOSURE_WATERMARK_FILE="$_PA_SCRIPT_DIR/disclosure-log.watermark"
fi

# Kernel built-in default (layer 6, docs/config-precedence.md) — used only
# if the committed file is somehow absent/unreadable/empty, so a broken
# checkout still fails safely CLOSED to "Anthropic only" rather than open to
# "everything".
_PA_BUILTIN_DEFAULT="anthropic"

pa_committed_file() { printf '%s\n' "$PROVIDER_ALLOWLIST_COMMITTED_FILE"; }
pa_local_file() { printf '%s\n' "$PROVIDER_ALLOWLIST_LOCAL_FILE"; }
pa_disclosure_log_file() { printf '%s\n' "$PROVIDER_DISCLOSURE_LOG_FILE"; }
# The COMMITTED anchor for the configured disclosure log (temperloop#1316).
pa_watermark_file() { printf '%s\n' "$PROVIDER_DISCLOSURE_WATERMARK_FILE"; }

# pa_valid_provider_name <name> — rc 0 iff it matches the same
# [a-z0-9-]-no-leading/trailing-hyphen slug shape validate-feature-docs.sh
# uses for feature slugs. A `case` pattern-set test, so a multi-line or
# otherwise adversarial name is rejected here rather than compared later.
pa_valid_provider_name() {
  case "${1:-}" in
    '') return 1 ;;
    *[!a-z0-9-]* | -* | *-) return 1 ;;
    *) return 0 ;;
  esac
}

# _pa_is_uint <s> — rc 0 iff <s> is a plain non-negative decimal integer with
# no leading zeros (except "0" itself) and at most 18 digits. EVERY value
# that reaches an arithmetic context — `$(( ))`, or the arithmetic operators
# `-eq`/`-lt`/`-gt` inside `[[ ]]` — passes through here first. Bash's
# arithmetic evaluator recursively expands variable CONTENTS and treats an
# array subscript as a command-substitution sink, so a log-supplied
# `seq` of `violations[$(touch /tmp/x)]` EXECUTES on `$((seq + 1))` — `set -u`
# is no defence when the payload names a variable that exists in scope. This
# guard, applied before the arithmetic and never after it, is the fix.
_pa_is_uint() {
  local s="${1:-}"
  case "$s" in
    '' | *[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  [[ "${#s}" -le 18 ]]
}

# _pa_is_hash <s> — rc 0 iff <s> is a 64-char lowercase hex sha256 digest.
# A log-supplied `hash` becomes the next line's expected `prev_hash`, so it
# is shape-checked before it is trusted as chain state.
_pa_is_hash() {
  local s="${1:-}"
  [[ "${#s}" -eq 64 ]] || return 1
  case "$s" in
    *[!0-9a-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _pa_parse_file <path> — one normalized (lowercased, trimmed) provider name
# per output line, `#`-comments and blank lines stripped, sorted+deduped.
# Prints nothing (rc 0) if the file does not exist — "no file" and "empty
# file" are deliberately the same observable shape here; callers that need
# to tell "no override" from "override narrows to nothing" use
# pa_local_file's -f test directly (see pa_local_list).
#
# The blank-line filter lives INSIDE the awk program, not in a downstream
# `| grep -v '^$'`: on a comment-only or empty file that grep matches nothing,
# exits 1, and under a caller's `set -o pipefail` fails the whole pipeline —
# which killed a `set -e` caller outright, with no WARN and no fallback.
_pa_parse_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ ! -r "$f" ]]; then
    echo "allowlist.sh: WARN cannot read $f (permissions) — treating it as empty; callers fail CLOSED" >&2
    return 0
  fi
  awk '
    {
      sub(/#.*/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "") print tolower($0)
    }
  ' "$f" | sort -u
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

# _pa_set_contains <set> <needle> — rc 0 iff one WHOLE line of <set> equals
# <needle> exactly. Deliberately not `printf '%s\n' "$set" | grep -Fx
# "$needle"`: grep reads a multi-line needle as several patterns (matching if
# ANY of them is present) and matches an empty needle against the empty line
# an empty set prints. Callers still validate the needle's shape first; this
# is the second half of the same defence.
_pa_set_contains() {
  local set="$1" needle="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<<"$set"
  return 1
}

# pa_narrowing_violations — prints any provider present in the personal
# override that is NOT in the committed ceiling (one per line) and returns
# rc 1 if any were found. rc 0 + no output if there is no override, or the
# override is a legal subset (or exact match) of the committed list. A
# malformed name in the override is itself a violation: an entry we cannot
# compare safely must never be treated as an allowed one.
pa_narrowing_violations() {
  local committed local_list found=0 p
  committed="$(pa_committed_list)"
  local_list="$(pa_local_list)" || return 0   # no override — nothing to violate
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if ! pa_valid_provider_name "$p"; then
      printf '%s\n' "$p"
      found=1
      continue
    fi
    if ! _pa_set_contains "$committed" "$p"; then
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
    # `|| true`: pa_narrowing_violations returns 1 as its NORMAL "violations
    # found" verdict, which under a caller's `set -e` aborted this function
    # before the REJECTED message and the documented rc 2 ever happened.
    violations="$(pa_narrowing_violations)" || true
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
# committed file allows" — and on any malformed provider name.
pa_is_allowed() {
  local provider effective
  provider="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  if ! pa_valid_provider_name "$provider"; then
    echo "allowlist.sh: DENY — malformed provider name (want lowercase [a-z0-9-], no leading/trailing '-', single line); denying by default (fail closed)" >&2
    return 1
  fi
  effective="$(pa_effective_list)" || {
    echo "allowlist.sh: DENY '$provider' — provider allowlist configuration is invalid (see above); denying by default (fail closed)" >&2
    return 1
  }
  _pa_set_contains "$effective" "$provider"
}

# ---------------------------------------------------------------------------
# The disclosure log: append-only, hash-chained, watermark-anchored.
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
# — the exact string pa_disclose hashes into `hash`, and that
# pa_verify_log_chain recomputes to check it. A dedicated function so the
# two call sites can never drift out of sync with each other.
#
# LENGTH-PREFIXED, not plain `|`-joined. `item_ref` is caller-controlled, so
# an unescaped delimiter made the encoding ambiguous: provider="anthropic"
# + item_ref="a|b" and provider="anthropic|a" + item_ref="b" produced the
# BYTE-IDENTICAL preimage and therefore the same digest, so INVALID-HASH
# could not tell one from the other. `<len>:<value>|` per field is injective
# for any field content, delimiter included.
_pa_canonical_entry() {
  local out="" field
  for field in "$@"; do
    out="$out${#field}:$field|"
  done
  printf '%s' "$out"
}

# _pa_watermark_file <logfile> — the anchor path for a given log.
#
# For the CONFIGURED log this is the configured anchor — in production the
# TRACKED file beside the committed allowlist, deliberately NOT the log's
# gitignored sibling (temperloop#1316). For any other log handed in ad hoc it
# falls back to the historical `<log>.watermark` sibling, so a caller that
# verifies some other file still gets THAT file's own anchor rather than the
# repo's committed one.
_pa_watermark_file() {
  if [[ "${1:-}" == "$PROVIDER_DISCLOSURE_LOG_FILE" ]]; then
    printf '%s\n' "$PROVIDER_DISCLOSURE_WATERMARK_FILE"
    return 0
  fi
  printf '%s\n' "${1%.jsonl}.watermark"
}

# The anchor file's on-disk grammar. It is a TRACKED file a stranger will
# open, so it carries a `#`-comment header explaining itself, and exactly one
# value line `<max_seq> <last_hash>`. The header is rewritten by every
# pa_disclose along with the value, so the two can never drift apart.
#
# `0` + the all-zero digest is the GENESIS value a fresh checkout ships: no
# entries disclosed yet, nothing for the log to descend from.
PA_WATERMARK_ZERO_HASH="0000000000000000000000000000000000000000000000000000000000000000"
# A QUOTED heredoc: nothing in this prose is a shell expansion, and the
# quoting keeps it that way no matter what punctuation the text grows.
_PA_WATERMARK_HEADER="$(
  cat <<'PA_WM_HEADER'
# disclosure-log.watermark — the COMMITTED anchor for the provider disclosure
# log (ADR 0028, temperloop#1250/#1316). Maintained by allowlist.sh's
# pa_disclose; the single value line below is "<max_seq> <last_hash>".
#
# The LOG itself is gitignored at .temperloop/model-comparison/disclosure-log.jsonl
# so no provider history and no content enters this repo. Only this anchor is
# tracked, and it carries neither: just how many entries the log is meant to
# have and what its tail hash is.
#
# COMMIT IT WHEN IT CHANGES. That is the whole mechanism: a log re-forged in
# place no longer matches the anchor recorded in git history, so hiding the
# re-forge means rewriting git history too — which leaves its own trace.
# validate-provider-disclosure.sh reports REFORGED-VS-GIT / WATERMARK-GIT-*
# when the live log stops descending from this file's committed value.
PA_WM_HEADER
)"

# _pa_watermark_read — first non-blank, non-comment line of the anchor, read
# from STDIN (so the same parser serves both the on-disk file and a
# `git show HEAD:<path>` blob, which is the point of having one).
_pa_watermark_read() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done
  return 0
}

# _pa_watermark_write <file> <seq> <hash> — header + value line, one write.
_pa_watermark_write() {
  {
    printf '%s\n' "$_PA_WATERMARK_HEADER"
    printf '%s %s\n' "$2" "$3"
  } >"$1"
}

# pa_watermark_init [file] — seed a GENESIS anchor (seq 0, the all-zero
# digest: nothing disclosed yet, so any log is trivially a forward extension
# of it) at the configured anchor path, or at an explicit one. Refuses to
# clobber an existing anchor — an anchor already carrying a real seq is the
# audit trail, and re-seeding it IS the re-forge this whole mechanism exists
# to make loud. This is how an adopting repo produces the file it then
# commits; it is not part of the disclose path.
pa_watermark_init() {
  local wm="${1:-$(pa_watermark_file)}"
  if [[ -e "$wm" ]]; then
    echo "allowlist.sh: pa_watermark_init: $wm already exists — refusing to overwrite an existing anchor (re-seeding one is indistinguishable from a re-forge)" >&2
    return 1
  fi
  mkdir -p "$(dirname "$wm")" 2>/dev/null || true
  _pa_watermark_write "$wm" 0 "$PA_WATERMARK_ZERO_HASH"
}

# ── The disclose lock ──────────────────────────────────────────────────────
# pa_disclose is a read-modify-append cycle (read the tail's seq/prev_hash,
# then append an entry chained onto it). Run concurrently — which is the
# EXPECTED usage in a model-comparison fan-out over several providers — two
# uncoordinated cycles both read the same tail and both append onto it, and
# the chain is permanently broken with no repair path: every subsequent
# verify fails, and the only way back to green is deleting the log. A lock
# directory (`mkdir` is atomic on every filesystem that matters, and there is
# no `flock` on macOS) serializes the cycle.
#
# Bounded, never an unbounded `until mkdir` spin: a lock leaked by a killed
# process would otherwise hang CI forever. Waiting caps out at
# _PA_LOCK_WAIT_TRIES * 0.1s and then FAILS (no entry written, loudly) rather
# than proceeding unserialized; a lockdir older than _PA_LOCK_STALE_MINUTES
# is treated as abandoned and reclaimed once.
_PA_LOCK_WAIT_TRIES=300      # 300 * 0.1s = 30s
_PA_LOCK_STALE_MINUTES=5

_pa_lock_is_stale() {
  local lockdir="$1" found
  [[ -d "$lockdir" ]] || return 1
  found="$(find "$lockdir" -maxdepth 0 -mmin "+$_PA_LOCK_STALE_MINUTES" 2>/dev/null)"
  [[ -n "$found" ]]
}

_pa_lock_acquire() {
  local lockdir="$1" tries=0 reclaimed=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [[ "$reclaimed" -eq 0 ]] && _pa_lock_is_stale "$lockdir"; then
      echo "allowlist.sh: reclaiming a stale disclosure-log lock ($lockdir, older than ${_PA_LOCK_STALE_MINUTES}m — a previous writer was killed)" >&2
      rm -rf "$lockdir" 2>/dev/null || true
      reclaimed=1
    fi
    tries=$((tries + 1))
    if [[ "$tries" -ge "$_PA_LOCK_WAIT_TRIES" ]]; then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

_pa_lock_release() {
  rm -rf "$1" 2>/dev/null || true
}

# pa_disclose <provider> <item_ref> — append ONE entry to the disclosure
# log for a send to a non-default provider. Refuses (rc 1, no line written)
# if <provider> is malformed or not currently in the effective allowlist —
# the log and the allowlist are paired mechanically, never by convention
# (ADR 0028 decision 2). Never logs content: only provider, item_ref, and
# timestamp.
pa_disclose() {
  local provider="${1:-}" item_ref="${2:-}" log lockdir rc

  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$provider" || -z "$item_ref" ]]; then
    echo "allowlist.sh: pa_disclose requires a non-empty provider and item_ref — no entry written" >&2
    return 1
  fi
  if ! pa_valid_provider_name "$provider"; then
    echo "allowlist.sh: pa_disclose REFUSED — malformed provider name (want lowercase [a-z0-9-], no leading/trailing '-', single line) — no entry written" >&2
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

  lockdir="$log.lock"
  if ! _pa_lock_acquire "$lockdir"; then
    echo "allowlist.sh: pa_disclose: could not acquire the disclosure-log lock ($lockdir) within $((_PA_LOCK_WAIT_TRIES / 10))s — refusing to append unserialized (a concurrent append would break the chain) — no entry written" >&2
    return 1
  fi
  # Guarded, not bare: under a caller's `set -e` a bare call that returned
  # non-zero would abort this function before the release below and LEAK the
  # lock, stalling every later disclose until the stale-reclaim window.
  rc=0
  _pa_disclose_locked "$provider" "$item_ref" "$log" || rc=$?
  _pa_lock_release "$lockdir"
  return "$rc"
}

# _pa_disclose_locked <provider> <item_ref> <log> — the read-modify-append
# cycle itself. NEVER call directly: pa_disclose holds the lock across it and
# releases it on every return path, success or failure.
_pa_disclose_locked() {
  local provider="$1" item_ref="$2" log="$3"
  local ts seq prev_hash canonical hash record wm

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -f "$log" && -s "$log" ]]; then
    if [[ ! -r "$log" ]]; then
      echo "allowlist.sh: pa_disclose: existing log ($log) is not readable — refusing to append onto a chain we cannot read" >&2
      return 1
    fi
    # seq comes from the tail entry's OWN `seq`, not from a line count: a
    # `grep -c` count desynchronizes from the chain the moment the file
    # carries a blank line or a comment, and `grep -c` also exits 1 while
    # printing `0` on an empty count, so the old `|| echo 0` fallback yielded
    # the two-line string "0\n0" and turned `$((... + 1))` into a bogus
    # "arithmetic syntax error" diagnostic.
    seq="$(tail -n 1 "$log" | jq -r '.seq // empty' 2>/dev/null)"
    prev_hash="$(tail -n 1 "$log" | jq -r '.hash // empty' 2>/dev/null)"
    if [[ -z "$prev_hash" || -z "$seq" ]]; then
      echo "allowlist.sh: pa_disclose: existing log ($log) has an unreadable last line — refusing to append onto a chain we cannot extend safely" >&2
      return 1
    fi
    if ! _pa_is_uint "$seq"; then
      echo "allowlist.sh: pa_disclose: existing log ($log) has a last entry whose seq is not a non-negative integer — refusing to append onto a chain we cannot extend safely" >&2
      return 1
    fi
    if ! _pa_is_hash "$prev_hash"; then
      echo "allowlist.sh: pa_disclose: existing log ($log) has a last entry whose hash is not a sha256 digest — refusing to append onto a chain we cannot extend safely" >&2
      return 1
    fi
    seq=$((seq + 1))
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

  printf '%s\n' "$record" >>"$log" || {
    echo "allowlist.sh: pa_disclose: failed to append to $log — no entry written" >&2
    return 1
  }

  # Watermark AFTER the append, inside the same lock: a crash between the two
  # leaves the log ahead of the anchor, which verifies as WATERMARK-STALE
  # (loud, recoverable) rather than as a phantom TRUNCATED.
  wm="$(_pa_watermark_file "$log")"
  mkdir -p "$(dirname "$wm")" 2>/dev/null || true
  if ! _pa_watermark_write "$wm" "$seq" "$hash"; then
    echo "allowlist.sh: pa_disclose: appended entry $seq but failed to update the watermark anchor ($wm) — the next verify will report WATERMARK-STALE until it is rebuilt" >&2
    return 1
  fi
  # The anchor is TRACKED (temperloop#1316) — an updated anchor left
  # uncommitted just means the audit trail is not yet anchored in git, so say
  # so once, on stderr, rather than letting it drift silently.
  echo "allowlist.sh: pa_disclose: disclosure-log anchor updated to seq=$seq ($wm) — COMMIT IT so the log stays anchored in git history" >&2
}

# pa_verify_log_chain <logfile> — format + hash-chain + watermark-anchor
# validity ONLY (no allowlist-membership check; the validator does that
# separately so this function stays reusable by anything that just wants "is
# this log internally consistent"). A missing/empty file with no watermark is
# legal (rc 0, no output) — a fresh checkout that never ran a comparison has
# no log yet. A missing/empty file WITH a watermark that records entries is
# TRUNCATED, not clean.
#   rc 0   clean (violations array empty)
#   rc 1   one or more violations (printed, one per line)
#   rc 2   CANNOT EVALUATE (jq missing, an unreadable log) — never silently
#          reports clean, and never returns non-zero with an EMPTY violation
#          list, which a caller cannot tell apart from clean
PA_RC_CHAIN_VIOLATIONS=1
PA_RC_CANNOT_EVALUATE=2
pa_verify_log_chain() {
  local log="${1:-}" lineno=0 entries=0 expect_seq=1 expect_prev="$PA_DISCLOSURE_GENESIS"
  local line keys schema_version ts provider item_ref seq prev_hash hash canonical recomputed
  local violations=0 bad last_seq=0 last_hash="$PA_DISCLOSURE_GENESIS"
  local wm wm_line wm_seq="" wm_hash="" wm_present=0 wm_ok=0

  if ! command -v jq >/dev/null 2>&1; then
    echo "CANNOT-EVALUATE  jq not found — cannot verify $log" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi

  wm="$(_pa_watermark_file "$log")"
  if [[ -e "$wm" ]]; then
    wm_present=1
    if [[ ! -r "$wm" ]]; then
      echo "CANNOT-EVALUATE  the watermark anchor ($wm) exists but is not readable — cannot verify $log" >&2
      return "$PA_RC_CANNOT_EVALUATE"
    fi
    wm_line="$(_pa_watermark_read <"$wm")"
    wm_seq="${wm_line%% *}"
    wm_hash="${wm_line#* }"
    if _pa_is_uint "$wm_seq" && _pa_is_hash "$wm_hash"; then
      wm_ok=1
    else
      echo "WATERMARK-MALFORMED  $wm — expected '<max_seq> <last_hash>', got '$wm_line'"
      violations=$((violations + 1))
    fi
  fi

  if [[ ! -e "$log" || ! -s "$log" ]]; then
    if [[ "$wm_ok" -eq 1 && "$wm_seq" -gt 0 ]]; then
      echo "TRUNCATED  $log — the watermark anchor records $wm_seq entr$( [[ "$wm_seq" -eq 1 ]] && echo y || echo ies ) but the log is absent or empty (the whole log was deleted or emptied)"
      violations=$((violations + 1))
    fi
    [[ "$violations" -eq 0 ]] || return "$PA_RC_CHAIN_VIOLATIONS"
    return 0
  fi

  if [[ ! -r "$log" ]]; then
    echo "CANNOT-EVALUATE  $log exists but is not readable — refusing to report a verdict on a log we cannot read" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi
  # Explicit fd, explicitly guarded: a bare `done <"$log"` redirect that FAILS
  # (an unreadable file) simply never runs the loop body, so the function
  # returned non-zero with NO violation lines — which a caller reading only
  # the printed violations cannot distinguish from a clean chain.
  exec 3<"$log" || {
    echo "CANNOT-EVALUATE  cannot open $log for reading" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  }

  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" ]] && continue
    entries=$((entries + 1))

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

    # Shape-check EVERY value that becomes arithmetic or chain state BEFORE
    # it is used as either. See _pa_is_uint's own comment for why this is a
    # code-execution boundary, not a tidiness check.
    bad=0
    if ! _pa_is_uint "$seq"; then
      echo "MALFORMED-SEQ  $log:$lineno — seq is not a non-negative integer"
      violations=$((violations + 1))
      bad=1
    fi
    if ! _pa_is_hash "$hash"; then
      echo "MALFORMED-HASH  $log:$lineno — hash is not a 64-character lowercase hex sha256 digest"
      violations=$((violations + 1))
      bad=1
    fi
    if [[ "$bad" -eq 1 ]]; then
      expect_prev="$hash"
      last_hash="$hash"
      if _pa_is_uint "$seq"; then
        expect_seq=$((seq + 1))
        last_seq="$seq"
      fi
      continue
    fi

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
    last_seq="$seq"
    last_hash="$hash"
  done
  exec 3<&-

  # ── Watermark anchor: the tail checks the chain itself cannot make ───────
  if [[ "$wm_ok" -eq 1 ]]; then
    if [[ "$last_seq" -lt "$wm_seq" ]]; then
      echo "TRUNCATED  $log — the log's last entry is seq=$last_seq but the watermark anchor records seq=$wm_seq (entries were removed from the END of the log, which the chain alone cannot see)"
      violations=$((violations + 1))
    elif [[ "$last_seq" -gt "$wm_seq" ]]; then
      echo "WATERMARK-STALE  $log — the log's last entry is seq=$last_seq, past the watermark anchor's seq=$wm_seq (an entry was appended outside pa_disclose, or a write was interrupted between the append and the anchor update)"
      violations=$((violations + 1))
    elif [[ "$last_hash" != "$wm_hash" ]]; then
      echo "REFORGED  $log — the log's tail hash does not match the watermark anchor's recorded hash (the chain was rebuilt end to end, which verifies clean on its own)"
      violations=$((violations + 1))
    fi
  elif [[ "$wm_present" -eq 0 && "$entries" -gt 0 ]]; then
    echo "WATERMARK-MISSING  $wm — a non-empty disclosure log has no watermark anchor; without it, truncation of the log's tail cannot be detected at all"
    violations=$((violations + 1))
  fi

  [[ "$violations" -eq 0 ]] || return "$PA_RC_CHAIN_VIOLATIONS"
  return 0
}

# pa_verify_watermark_git_anchor <logfile> — the check pa_verify_log_chain
# STRUCTURALLY cannot make (temperloop#1316): does the live log still descend
# from the anchor as recorded in GIT HISTORY?
#
# WHY THIS IS A SEPARATE FUNCTION. pa_verify_log_chain compares the log
# against the anchor ON DISK. Both files are locally writable, so a process
# that rewrites the log and its anchor together verifies clean there — that is
# exactly the "full re-forge leaves no trace" hole. This function reads the
# anchor's COMMITTED blob (`git show HEAD:<path>`) instead, which a local
# rewrite cannot touch without also rewriting git history. It is kept out of
# pa_verify_log_chain so that function stays git-free and reusable as its own
# header promises ("is this log internally consistent"), and so this one can
# be pointed at a synthesized fixture repo in a test.
#
#   rc 0   clean, or NOT APPLICABLE (the anchor is not inside a git work tree
#          at all — a scratch/fixture path with no committed anchor to
#          descend from; the validator separately requires the repo's real
#          anchor to be tracked)
#   rc 1   one or more violations (printed to stdout, one per line)
#   rc 2   CANNOT EVALUATE — never a silent pass, never non-zero with an
#          empty violation list
pa_verify_watermark_git_anchor() {
  local log="${1:-}" wm wm_dir wm_phys toplevel rel blob line c_seq c_hash found

  wm="$(_pa_watermark_file "$log")"

  if ! command -v git >/dev/null 2>&1; then
    echo "CANNOT-EVALUATE  git not found — cannot check the disclosure log against its COMMITTED anchor ($wm)" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "CANNOT-EVALUATE  jq not found — cannot check the disclosure log against its COMMITTED anchor ($wm)" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi

  # Physical resolution + `CDPATH=''` for the same two reasons the validator's
  # own committed-file block documents at length: a logical path under a
  # symlinked ancestor (macOS /tmp -> /private/tmp) does not prefix-match a
  # physically-resolved repo root, and a bare `cd` with an inherited CDPATH
  # echoes its target and corrupts the substitution.
  if ! wm_dir="$(CDPATH='' cd -P "$(dirname "$wm")" 2>/dev/null && pwd)"; then
    echo "CANNOT-EVALUATE  cannot resolve the watermark anchor's directory ($(dirname "$wm")) — refusing to report a verdict on an anchor whose location could not be established" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi
  wm_phys="$wm_dir/$(basename "$wm")"

  if ! toplevel="$(git -C "$wm_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    return 0
  fi
  [[ -n "$toplevel" ]] || return 0

  if ! git -C "$toplevel" ls-files --error-unmatch -- "$wm_phys" >/dev/null 2>&1; then
    echo "WATERMARK-NOT-TRACKED  $wm — the disclosure-log anchor sits inside a git work tree ($toplevel) but is NOT tracked; an untracked anchor can be rewritten in the same motion as the log, so a full re-forge would leave no trace (temperloop#1316)"
    return "$PA_RC_CHAIN_VIOLATIONS"
  fi

  rel="${wm_phys#"$toplevel"/}"
  # An anchor tracked in the INDEX but not yet in HEAD is the commit that
  # first adds it — there is nothing committed to descend from yet, and the
  # tracked-ness check above already fired if it were merely on disk.
  if ! blob="$(git -C "$toplevel" show "HEAD:$rel" 2>/dev/null)" || [[ -z "$blob" ]]; then
    return 0
  fi

  line="$(printf '%s\n' "$blob" | _pa_watermark_read)"
  c_seq="${line%% *}"
  c_hash="${line#* }"
  if ! _pa_is_uint "$c_seq" || ! _pa_is_hash "$c_hash"; then
    echo "WATERMARK-GIT-MALFORMED  $rel — the COMMITTED anchor blob (HEAD:$rel) carries no '<max_seq> <last_hash>' value line, so the log cannot be checked against git history at all"
    return "$PA_RC_CHAIN_VIOLATIONS"
  fi

  # seq 0 is the genesis anchor a fresh checkout ships: nothing disclosed yet,
  # so every log is trivially a forward extension of it.
  if [[ "$c_seq" -eq 0 ]]; then
    return 0
  fi

  if [[ ! -f "$log" || ! -s "$log" ]]; then
    echo "WATERMARK-GIT-DIVERGED  $log — the COMMITTED anchor (HEAD:$rel) records seq=$c_seq, but the log is absent or empty; the log no longer descends from the anchor recorded in git history"
    return "$PA_RC_CHAIN_VIOLATIONS"
  fi
  if [[ ! -r "$log" ]]; then
    echo "CANNOT-EVALUATE  $log exists but is not readable — cannot check it against the COMMITTED anchor (HEAD:$rel)" >&2
    return "$PA_RC_CANNOT_EVALUATE"
  fi

  # `--argjson` fed a value _pa_is_uint already proved is a plain integer.
  found="$(jq -r --argjson want "$c_seq" '
      select(type == "object") | select(.seq == $want) | .hash // empty
    ' "$log" 2>/dev/null | head -n 1)"
  if [[ -z "$found" ]]; then
    echo "WATERMARK-GIT-DIVERGED  $log — the COMMITTED anchor (HEAD:$rel) records seq=$c_seq, but the log has no entry at that seq; it was truncated below, or rebuilt shorter than, the anchor recorded in git history"
    return "$PA_RC_CHAIN_VIOLATIONS"
  fi
  if [[ "$found" != "$c_hash" ]]; then
    echo "REFORGED-VS-GIT  $log — the log's entry at seq=$c_seq hashes to '$found' but the COMMITTED anchor (HEAD:$rel) records '$c_hash'; the log was re-forged. Rewriting the log and its on-disk anchor together is no longer enough — the anchor in git history still disagrees"
    return "$PA_RC_CHAIN_VIOLATIONS"
  fi
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
    verify-committed-anchor)
      pa_verify_watermark_git_anchor "${2:-$(pa_disclosure_log_file)}"
      ;;
    init-watermark)
      pa_watermark_init "${2:-}"
      ;;
    watermark)
      pa_watermark_file
      ;;
    *)
      echo "usage: allowlist.sh {is-allowed <provider>|committed|effective|disclose <provider> <item_ref>|verify-log [file]|verify-committed-anchor [file]|watermark|init-watermark [file]}" >&2
      exit 64
      ;;
  esac
fi
