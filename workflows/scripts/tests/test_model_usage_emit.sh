#!/usr/bin/env bash
#
# test_model_usage_emit.sh — tests for workflows/scripts/emit-model-usage.sh
# and workflows/scripts/validate-model-usage-emit.sh (temperloop#1253, epic
# #1225 "model comparison harness", ADR 0026/0028).
#
# Covers every acceptance guarantee of the attribution-emit-family item:
#   1. one JSONL record per spawned seat, monthly rotation, schema_version
#      from day one, raw UNTRUNCATED session id as the join key
#   2. CONTENT-level validation (not mere presence) — a fixture record with
#      valid SHAPE but an out-of-enum provider (or model family) FAILS
#   3. no cross-repo operator identifier (no `host` field) — ADR 0028
#   4. ADR 0020 inheritance per the L0 spike: requestId dedup is documented
#      N/A (CLI envelope is the declared owner); cache-class weighting is
#      genuinely INHERITED from SPEND_WEIGHT_* (build.config.sh), not a
#      second hardcoded copy
#   5. the validator uses a STRICT JSON parser (python3, NaN/Infinity
#      rejected) rather than jq (which silently coerces them) — demonstrated
#      directly against the same fixture line under both parsers
#
# For every guarantee above that is a live MECHANISM (not a doc-presence
# fact), this suite includes a TAMPER test: a fixture copy of the production
# script(s) with the mechanism surgically removed, proving the check is
# actually load-bearing (the suite would go RED on the untampered originals
# if that check silently vanished) rather than a check that never fires.
#
# Synthetic lake under a throwaway tmpdir (MODEL_USAGE_RAW_DIR). Zero
# network; never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-model-usage.sh"
LINT="$REPO/workflows/scripts/validate-model-usage-emit.sh"
ALLOWLIST="$REPO/workflows/scripts/model-comparison/allowlist.sh"
PROVIDER_TXT="$REPO/workflows/scripts/model-comparison/provider-allowlist.txt"
BUILD_CONFIG="$REPO/workflows/scripts/build/build.config.sh"
TELEMETRY_MD="$REPO/docs/features/telemetry.md"
MODELCMP_MD="$REPO/docs/features/model-comparison.md"
PIPELINE_DRIVE_SH="$REPO/workflows/scripts/build/pipeline-drive.sh"
RETRO_JUDGE_SPAWN_SH="$REPO/workflows/scripts/build/pipeline-retro-judge-spawn.sh"
ENVELOPE_LIB="$REPO/workflows/scripts/lib/model-usage-envelope.sh"
PORTABLE_TIMEOUT="$REPO/workflows/scripts/lib/portable-timeout.sh"
[ -f "$PORTABLE_TIMEOUT" ] || { echo "FATAL: portable-timeout.sh not found at $PORTABLE_TIMEOUT" >&2; exit 1; }
# shellcheck source=workflows/scripts/lib/portable-timeout.sh
source "$PORTABLE_TIMEOUT"

[ -f "$EMIT" ] || { echo "FATAL: emit-model-usage.sh not found at $EMIT" >&2; exit 1; }
[ -f "$LINT" ] || { echo "FATAL: validate-model-usage-emit.sh not found at $LINT" >&2; exit 1; }
[ -f "$PIPELINE_DRIVE_SH" ] || { echo "FATAL: pipeline-drive.sh not found at $PIPELINE_DRIVE_SH" >&2; exit 1; }
[ -f "$RETRO_JUDGE_SPAWN_SH" ] || { echo "FATAL: pipeline-retro-judge-spawn.sh not found at $RETRO_JUDGE_SPAWN_SH" >&2; exit 1; }
[ -f "$ENVELOPE_LIB" ] || { echo "FATAL: model-usage-envelope.sh not found at $ENVELOPE_LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/model-usage-emit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Layer an ADDITIONAL EXIT cleanup action on top of whatever EXIT trap is
# currently registered, rather than replacing it outright — a bare
# `trap ... EXIT` REPLACES any prior EXIT trap, and this suite's outer
# `rm -rf "$TMP"` trap above must never be silently dropped by a later
# fixture-permission-restore trap (BLOCKING 3 fixtures below chmod a dir
# unreadable and must restore it even on a mid-fixture failure).
add_exit_cleanup() {
  local existing
  existing="$(trap -p EXIT | sed -e "s/^trap -- '//" -e "s/' EXIT\$//")"
  # Intentional: $1 and $existing must expand NOW (capturing the caller's
  # exact cleanup command and the trap text as it stands at this call), not
  # be deferred to signal time — this isn't the usual SC2064 footgun.
  # shellcheck disable=SC2064
  trap "$1; $existing" EXIT
}

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}
check_not() { # <desc> <cmd...>  -- passes iff the command FAILS
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$d" "command unexpectedly succeeded: $*"; else ok "$d"; fi
}

# emit <lake-subdir> <session-id> <args...> -> sets EMIT_OUT / EMIT_ERR / EMIT_RC
emit() {
  local sub="$1" sess="$2"; shift 2
  local dir="$TMP/$sub"
  mkdir -p "$dir"
  EMIT_OUT="$(MODEL_USAGE_RAW_DIR="$dir" CLAUDE_CODE_SESSION_ID="$sess" \
    bash "$EMIT" "$@" 2>"$TMP/err.txt")"
  EMIT_RC=$?
  EMIT_ERR="$(cat "$TMP/err.txt")"
}
lake_lines() { cat "$TMP/$1"/model-usage-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
lake_file()  { printf '%s\n' "$TMP/$1"/model-usage-*.jsonl; }

echo "── 1. a good cli-envelope record: shape, monthly rotation, raw untruncated session id ──"
LONGSESS="sess-0123456789abcdef-untruncated-join-key-check"
emit l1 "$LONGSESS" --seat pipeline-drive-safe --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --duration-ms 1500 --outcome-ref issue:1253 --repo Towheads/temperloop
check_eq "exit 0" "0" "$EMIT_RC"
check_eq "one line appended to the lake" "1" "$(lake_lines l1)"
month="$(date -u +%Y-%m)"
check "monthly-rotated filename" bash -c "ls '$TMP/l1/model-usage-${month}.jsonl' >/dev/null 2>&1"
check_eq "schema_version present from day one" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.schema_version')"
check_eq "session_id is the FULL raw value, never truncated" "$LONGSESS" "$(printf '%s' "$EMIT_OUT" | jq -r '.session_id')"
check_eq "seat carries the role name" "pipeline-drive-safe" "$(printf '%s' "$EMIT_OUT" | jq -r '.seat')"
check_eq "model carried verbatim" "claude-sonnet-5" "$(printf '%s' "$EMIT_OUT" | jq -r '.model')"
check_eq "provider carried" "anthropic" "$(printf '%s' "$EMIT_OUT" | jq -r '.provider')"
check_eq "usage_source carried" "cli-envelope" "$(printf '%s' "$EMIT_OUT" | jq -r '.usage_source')"
check_eq "input token count" "100" "$(printf '%s' "$EMIT_OUT" | jq -r '.tokens.input')"
check_eq "output token count" "50" "$(printf '%s' "$EMIT_OUT" | jq -r '.tokens.output')"
check_eq "outcome_ref carried" "issue:1253" "$(printf '%s' "$EMIT_OUT" | jq -r '.outcome_ref')"
check_eq "duration_ms carried" "1500" "$(printf '%s' "$EMIT_OUT" | jq -r '.duration_ms')"
check_eq "NO host field is ever emitted (ADR 0028)" "false" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("host")')"

echo "── 2. an attribution-only record (usage_source=unavailable): tokens/provider null ──"
emit l2 sess-2 --seat worker-attribution --model claude-sonnet-5 --usage-source unavailable --outcome-ref pr:456
check_eq "exit 0" "0" "$EMIT_RC"
check_eq "provider is null" "null" "$(printf '%s' "$EMIT_OUT" | jq -r '.provider')"
check_eq "tokens is null" "null" "$(printf '%s' "$EMIT_OUT" | jq -c '.tokens')"
check_eq "weighted_units is null" "null" "$(printf '%s' "$EMIT_OUT" | jq -c '.weighted_units')"

echo "── 3. cache-class weighting is genuinely INHERITED from SPEND_WEIGHT_* (build.config.sh) ──"
# advisory A8: derive the expected figure LIVE from build.config.sh's own
# SPEND_WEIGHT_* values rather than hardcoding today's numbers (the suite
# used to assert literal 382/5132) — this assertion is about INHERITANCE (a
# future weight retune in build.config.sh must move both emit's output and
# this test's expectation together), not about today's specific weights, so
# it must not silently start failing (or worse, silently keep "passing" for
# the wrong reason) the day someone retunes SPEND_WEIGHT_*.
weights_from_config() { # prints "IN CACHE_READ CACHE_CREATE OUTPUT"
  bash -c "source '$BUILD_CONFIG' >/dev/null 2>&1; printf '%s %s %s %s' \"\${SPEND_WEIGHT_INPUT:?}\" \"\${SPEND_WEIGHT_CACHE_READ:?}\" \"\${SPEND_WEIGHT_CACHE_CREATE:?}\" \"\${SPEND_WEIGHT_OUTPUT:?}\""
}
read -r W_IN W_CR W_CC W_OUT <<<"$(weights_from_config)"
if [ -z "$W_IN" ] || [ -z "$W_CR" ] || [ -z "$W_CC" ] || [ -z "$W_OUT" ]; then
  echo "FATAL: could not resolve SPEND_WEIGHT_* from $BUILD_CONFIG" >&2
  exit 1
fi
# Fixed token mix used throughout this suite: input=100 cache_read=200 cache_creation=10 output=50.
wu() { python3 -c "import math; print(math.floor(100*$1 + 200*$2 + 10*$3 + 50*$4))"; }
expected_default="$(wu "$W_IN" "$W_CR" "$W_CC" "$W_OUT")"
check_eq "weighted_units matches the formula computed LIVE from build.config.sh's own default SPEND_WEIGHT_* values (not a hardcoded literal)" \
  "$expected_default" "$(printf '%s' "$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 --outcome-ref issue:1 --print-only)" | jq -r '.weighted_units')"
# Override ONE weight via env and confirm the computed figure actually moves —
# proof this is real sourcing from build.config.sh's `:=` seam, not a copied
# literal — and that it moves to the value computed WITH the override, not
# some other hardcoded number.
OVERRIDE_W_OUT=100
expected_override="$(wu "$W_IN" "$W_CR" "$W_CC" "$OVERRIDE_W_OUT")"
OVERRIDE_OUT="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT="$OVERRIDE_W_OUT" \
  bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic \
  --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only)"
check_eq "an env override of SPEND_WEIGHT_OUTPUT changes weighted_units to the value computed WITH the override (genuine inheritance, not a hardcoded copy)" \
  "$expected_override" "$(printf '%s' "$OVERRIDE_OUT" | jq -r '.weighted_units')"

echo "── 4. malformed / contradictory input warns and exits 0, writes NO record (WARN, DON'T DROP) ──"
emit l4a sess-4 --model claude-sonnet-5 --usage-source unavailable --outcome-ref pr:1
check_eq "missing --seat: exit 0" "0" "$EMIT_RC"
check_eq "...and no record written" "0" "$(lake_lines l4a)"
emit l4b sess-4 --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --outcome-ref pr:1
check_eq "cli-envelope missing token flags: exit 0, warns" "0" "$EMIT_RC"
check "...names the requirement" bash -c "grep -Fq 'requires --input-tokens' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and no record written" "0" "$(lake_lines l4b)"
emit l4c sess-4 --seat x --model claude-sonnet-5 --usage-source unavailable --provider anthropic --outcome-ref pr:1
check_eq "unavailable + provider (contradiction): exit 0" "0" "$EMIT_RC"
check_eq "...and no record written" "0" "$(lake_lines l4c)"
emit l4d sess-4 --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic \
  --input-tokens two --output-tokens 1 --cache-read-tokens 0 --cache-creation-tokens 0 --outcome-ref pr:1
check_eq "non-numeric token count: exit 0, warns" "0" "$EMIT_RC"
check "...naming the offending flag" bash -c "grep -Fq -- '--input-tokens must be a non-negative integer' <<<\"\$1\"" _ "$EMIT_ERR"

echo "── 5. the validator: passes on an empty tree, passes on a good record ──"
check "validator passes on the real (record-less) tree" bash "$LINT"
check "validator passes on a good print-only record" bash -c \
  "MODEL_USAGE_RAW_DIR='$TMP/l1' bash '$EMIT' --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 1 --output-tokens 1 --cache-read-tokens 0 --cache-creation-tokens 0 --outcome-ref issue:1 --print-only > '$TMP/good.jsonl' && bash '$LINT' --file '$TMP/good.jsonl'"

echo "── 6. CONTENT-level validation: valid SHAPE, out-of-enum PROVIDER or MODEL, must FAIL ──"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":"openai","usage_source":"cli-envelope","tokens":{"input":1,"output":1,"cache_read":0,"cache_creation":0},"weighted_units":6,"duration_ms":null,"outcome_ref":"issue:1"}\n' > "$TMP/bad-provider.jsonl"
check_not "the ACCEPTANCE-MANDATED case: valid shape, provider=openai (not in the ADR 0028 committed allowlist) FAILS" \
  bash "$LINT" --file "$TMP/bad-provider.jsonl"
check "...and names the violation" bash -c \
  "bash '$LINT' --file '$TMP/bad-provider.jsonl' 2>&1 | grep -F \"PROVIDER-ENUM: provider 'openai'\" >/dev/null"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-turbo-1","provider":"anthropic","usage_source":"cli-envelope","tokens":{"input":1,"output":1,"cache_read":0,"cache_creation":0},"weighted_units":6,"duration_ms":null,"outcome_ref":"issue:1"}\n' > "$TMP/bad-model.jsonl"
check_not "valid shape, model='claude-turbo-1' (no known family) FAILS" bash "$LINT" --file "$TMP/bad-model.jsonl"
check "...and names the violation" bash -c \
  "bash '$LINT' --file '$TMP/bad-model.jsonl' 2>&1 | grep -F 'MODEL-ENUM' >/dev/null"

echo "── 7. NO CROSS-REPO IDENTIFIER: a record carrying 'host' FAILS (ADR 0028) ──"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:1","host":"my-mac"}\n' > "$TMP/host.jsonl"
check_not "a record carrying host FAILS" bash "$LINT" --file "$TMP/host.jsonl"
check "...and names it NO-HOST" bash -c "bash '$LINT' --file '$TMP/host.jsonl' 2>&1 | grep -F 'NO-HOST' >/dev/null"

echo "── 7b. BLOCKING 2: CLOSED SCHEMA — unknown top-level fields BEYOND 'host' (hostname/operator/machine_id) FAIL too ──"
# The old check was a one-key denylist (only the literal name 'host'). A
# record carrying THREE OTHER cross-repo operator identifiers, none of them
# spelled 'host', used to pass at exit 0 — this is the acceptance-mandated
# demonstration that the fix is a real closed schema, not a bigger denylist.
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:1","hostname":"travis-mbp.local","operator":"travnew@yahoo.com","machine_id":"AABBCC"}\n' > "$TMP/cross-repo-ids.jsonl"
check_not "a record carrying hostname/operator/machine_id (none named 'host') FAILS" \
  bash "$LINT" --file "$TMP/cross-repo-ids.jsonl"
check "...names it SCHEMA-CLOSED and lists all three unexpected fields" bash -c \
  "out=\$(bash '$LINT' --file '$TMP/cross-repo-ids.jsonl' 2>&1); grep -Fq 'SCHEMA-CLOSED' <<<\"\$out\" && grep -Fq 'hostname' <<<\"\$out\" && grep -Fq 'operator' <<<\"\$out\" && grep -Fq 'machine_id' <<<\"\$out\""

echo "── 8. usage_source / tokens / provider pairing is enforced as a SHAPE violation ──"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":"anthropic","usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:1"}\n' > "$TMP/pairing.jsonl"
check_not "unavailable + non-null provider FAILS" bash "$LINT" --file "$TMP/pairing.jsonl"

echo "── 9. THE STRICT-PARSER TRAP: jq -e . silently accepts NaN; the validator (python3) must reject it ──"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":"anthropic","usage_source":"cli-envelope","tokens":{"input":NaN,"output":1,"cache_read":0,"cache_creation":0},"weighted_units":6,"duration_ms":null,"outcome_ref":"issue:1"}\n' > "$TMP/nan.jsonl"
check "jq -e . WRONGLY accepts the NaN-corrupted line (the documented trap)" \
  bash -c "jq -e . '$TMP/nan.jsonl' >/dev/null 2>&1"
check_not "the validator (strict python3 parse) correctly REJECTS the same line" bash "$LINT" --file "$TMP/nan.jsonl"
check "...and names it STRICT-PARSE" bash -c "bash '$LINT' --file '$TMP/nan.jsonl' 2>&1 | grep -F 'STRICT-PARSE' >/dev/null"

echo "── 10. outcome_ref shape is content-checked (issue:/pr: prefix required) ──"
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"1253"}\n' > "$TMP/badref.jsonl"
check_not "an outcome_ref with no issue:/pr: prefix FAILS" bash "$LINT" --file "$TMP/badref.jsonl"

# ---------------------------------------------------------------------------
# MUTATION TESTS — break the mechanism in a FIXTURE COPY, confirm the suite's
# own assertion goes RED (the bad fixture wrongly passes), then restore and
# confirm GREEN. Never mutates the real checkout.
# ---------------------------------------------------------------------------
FIXR="$TMP/fixture"
mkdir -p "$FIXR/workflows/scripts/model-comparison" "$FIXR/workflows/scripts/build"
cp "$EMIT" "$FIXR/workflows/scripts/emit-model-usage.sh"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
cp "$ALLOWLIST" "$FIXR/workflows/scripts/model-comparison/allowlist.sh"
cp "$PROVIDER_TXT" "$FIXR/workflows/scripts/model-comparison/provider-allowlist.txt"
cp "$BUILD_CONFIG" "$FIXR/workflows/scripts/build/build.config.sh"
# Complete (untampered) driver copies too — several sections below invoke
# $FIXR's validate-model-usage-emit.sh with NEITHER --file NOR --scan-dir
# (e.g. section 11's presence-lint mutation), which resolves spawn-site
# coverage's DEFAULT scan dir to $FIXR/workflows/scripts/build — that must
# be a real, fully-wired copy or those unrelated presence/content mutations
# would spuriously fail on a coverage gap that has nothing to do with what
# they're testing. Section 33+ below uses the SEPARATE $COVR tree (below)
# for actual coverage mutations, never this one.
mkdir -p "$FIXR/workflows/scripts/lib"
cp "$PIPELINE_DRIVE_SH" "$FIXR/workflows/scripts/build/pipeline-drive.sh"
cp "$RETRO_JUDGE_SPAWN_SH" "$FIXR/workflows/scripts/build/pipeline-retro-judge-spawn.sh"
cp "$ENVELOPE_LIB" "$FIXR/workflows/scripts/lib/model-usage-envelope.sh"
chmod +x "$FIXR/workflows/scripts/"*.sh "$FIXR/workflows/scripts/model-comparison/allowlist.sh" \
  "$FIXR/workflows/scripts/build/pipeline-drive.sh" "$FIXR/workflows/scripts/build/pipeline-retro-judge-spawn.sh"

# A SEPARATE fixture tree just for spawn-site coverage (section 31+ below) —
# --scan-dir points the validator's coverage checks at THIS dir, never the
# real workflows/scripts/build/, so every mutation below is on a disposable
# copy. Kept separate from $FIXR/workflows/scripts/build above (that one is
# scoped to the emit/lint presence+content mutations, and stays a clean
# byte-for-byte build.config.sh-only build dir).
COVR="$TMP/coverage-scan"
mkdir -p "$COVR"
cp "$PIPELINE_DRIVE_SH" "$COVR/pipeline-drive.sh"
cp "$RETRO_JUDGE_SPAWN_SH" "$COVR/pipeline-retro-judge-spawn.sh"
# reset_covr <label> — restore both fixture files to the pristine originals.
reset_covr() {
  cp "$PIPELINE_DRIVE_SH" "$COVR/pipeline-drive.sh"
  cp "$RETRO_JUDGE_SPAWN_SH" "$COVR/pipeline-retro-judge-spawn.sh"
  rm -f "$COVR"/*.sh.orig "$COVR/pipeline-drive-experimental.sh" "$COVR/fake-new-driver.sh"
}

echo "── 11. MUTATION: presence-lint catches emit-model-usage.sh losing its exec bit ──"
check "fixture copy passes before tampering" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod -x "$FIXR/workflows/scripts/emit-model-usage.sh"
check_not "lint FAILS when emit-model-usage.sh loses its exec bit" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
check "restored: fixture copy passes again" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"

echo "── 11b. MUTATION: the closed-schema (SCHEMA-CLOSED) check is independently load-bearing for a NON-host field ──"
# Neuter ONLY the generic extra-field check, leaving the named 'if host in
# rec' branch ACTIVE — proves SCHEMA-CLOSED is doing real, independent work
# for identifiers the named branch never looks at (hostname/operator/
# machine_id), not that the named branch alone was already sufficient.
check_not "BEFORE tamper: fixture validator rejects hostname/operator/machine_id" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/cross-repo-ids.jsonl"
sed -e 's/extra = sorted(k for k in rec if k not in required)/extra = []/' \
  "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (closed-schema check neutered, no-host branch left ACTIVE): hostname/operator/machine_id WRONGLY passes" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/cross-repo-ids.jsonl"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: hostname/operator/machine_id rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/cross-repo-ids.jsonl"

echo "── 12. MUTATION: the strict-parse NaN rejection is load-bearing ──"
# This fixture is otherwise a FULLY VALID, fully-compliant record plus one
# EXTRA field the schema-shape checks never look at, carrying NaN. No
# downstream type check touches this field, so this isolates the
# STRICT-PARSE step's own load-bearing-ness: if parse_constant is removed,
# NOTHING else in the validator can catch the corruption, and the record
# wrongly passes end to end. (The tokens.input placement used in section 9
# above is a fine demonstration of the jq-vs-python TRAP, but is a poor
# mutation-test fixture: tokens.input also fails the separate isinstance(v,
# int) check, so removing parse_constant there does not, by itself, prove
# strict-parse was the thing catching it.)
#
# BLOCKING 2 knock-on: this fixture used to put the extra field at the TOP
# LEVEL of the record — but BLOCKING 2 closed the top-level schema, so a
# top-level extra field is now caught by the generic SCHEMA-CLOSED check
# too, which would no longer isolate strict-parse's OWN load-bearing-ness
# (removing parse_constant would still correctly fail the record, just for a
# different reason). Retargeted: the extra field now lives INSIDE the
# `tokens` object instead — usage_source=cli-envelope so tokens is a real
# object, and the tokens-shape check only enumerates its four named keys
# (input/output/cache_read/cache_creation), never checking for extras within
# it — so this nested placement is genuinely untouched by every OTHER check
# in the validator, top-level closed-schema included.
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":"anthropic","usage_source":"cli-envelope","tokens":{"input":1,"output":1,"cache_read":0,"cache_creation":0,"junk_unvalidated_field":NaN},"weighted_units":6,"duration_ms":null,"outcome_ref":"issue:1"}\n' > "$TMP/nan-isolated.jsonl"
check_not "BEFORE tamper: the fixture validator still rejects the isolated-NaN fixture" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/nan-isolated.jsonl"
cp "$FIXR/workflows/scripts/validate-model-usage-emit.sh" "$TMP/lint-orig-for-nan.sh"
sed -e 's/parse_constant=reject_nonfinite/ /' "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (parse_constant hook removed): the isolated-NaN fixture WRONGLY passes — proves the check was load-bearing" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/nan-isolated.jsonl"
cp "$TMP/lint-orig-for-nan.sh" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: the isolated-NaN fixture is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/nan-isolated.jsonl"

echo "── 13. MUTATION: the model-family enum check is load-bearing ──"
check_not "BEFORE tamper: fixture validator rejects claude-turbo-1" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-model.jsonl"
sed -e 's/if segments\[0\] != "claude" or not any(seg in KNOWN_FAMILIES for seg in segments\[1:\]):/if False:/' \
  "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (family check neutered): claude-turbo-1 WRONGLY passes" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-model.jsonl"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: claude-turbo-1 is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-model.jsonl"

echo "── 14. MUTATION: the provider-allowlist membership check is load-bearing ──"
check_not "BEFORE tamper: fixture validator rejects provider=openai" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-provider.jsonl"
# Intentional: matching a literal '$prov' in the source text, never expanding it here.
# shellcheck disable=SC2016
sed -e 's/if ! pa_is_allowed "\$prov" 2>\/dev\/null; then/if false; then/' \
  "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (allowlist check neutered): provider=openai WRONGLY passes" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-provider.jsonl"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: provider=openai is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/bad-provider.jsonl"

echo "── 15. MUTATION: the no-host guarantee — defense-in-depth after BLOCKING 2 ──"
# BLOCKING 2's closed-schema check made the named 'if host in rec' branch
# REDUNDANT for catching a host-carrying record (not for its MESSAGE — that
# stays specific and ADR-0028-quoting). So removing ONLY the named branch no
# longer lets the record wrongly pass: the generic SCHEMA-CLOSED catch-all
# backstops it. This is deliberately a CHANGED assertion from before BLOCKING
# 2 (it used to assert "wrongly passes"; now it asserts "still rejected, via
# a different message") — see section 15b below for the mutation that
# isolates the TRUE combined load-bearing-ness the old version of this
# section used to test alone.
check_not "BEFORE tamper: fixture validator rejects a record carrying host" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
sed -e 's/if "host" in rec:/if False:/' "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "AFTER tamper (named no-host branch removed): STILL correctly REJECTED — the generic SCHEMA-CLOSED catch-all backstops it" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
check "...now via the generic SCHEMA-CLOSED message, not the specific NO-HOST one" bash -c \
  "bash '$FIXR/workflows/scripts/validate-model-usage-emit.sh' --file '$TMP/host.jsonl' 2>&1 | grep -F 'SCHEMA-CLOSED' >/dev/null"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: a record carrying host is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
check "...restored message is the specific NO-HOST one again" bash -c \
  "bash '$FIXR/workflows/scripts/validate-model-usage-emit.sh' --file '$TMP/host.jsonl' 2>&1 | grep -F 'NO-HOST' >/dev/null"

echo "── 15b. MUTATION: with BOTH the no-host branch AND the closed-schema check neutered together, a host record WRONGLY passes ──"
# This isolates the combined load-bearing-ness section 15 used to test via a
# single check alone, pre-BLOCKING-2: proves there is still SOME real
# mechanism enforcing the ADR 0028 no-cross-repo-identifier guarantee, even
# though the two checks are now individually redundant with each other for
# this specific 'host' field.
check_not "BEFORE tamper: fixture validator rejects a record carrying host" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
sed -e 's/if "host" in rec:/if False:/' -e 's/extra = sorted(k for k in rec if k not in required)/extra = []/' \
  "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (BOTH the no-host branch AND closed-schema neutered): a record carrying host WRONGLY passes" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: a record carrying host is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"

echo "── 16. MUTATION: cache-class weighting is sourced from build.config.sh, not hardcoded ──"
# advisory A8: derive both expected figures from the SAME live-sourced
# weights ($W_IN/$W_CR/$W_CC/$W_OUT, $expected_default, $expected_override)
# computed in section 3 above, instead of the hardcoded 382/5132 this test
# used to assert — so this test, too, distinguishes "someone retuned the
# weights" from "the inheritance regressed" rather than conflating them.
BEFORE="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT="$OVERRIDE_W_OUT" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "BEFORE tamper: SPEND_WEIGHT_OUTPUT override moves weighted_units to the value computed WITH the override" "$expected_override" "$BEFORE"
# Tamper: hardcode the output weight literal (to today's UN-overridden
# default, $W_OUT) instead of sourcing it, breaking genuine inheritance from
# build.config.sh — the env override should then have no effect at all.
# Intentional: matching a literal '${SPEND_WEIGHT_OUTPUT:-0}' in the source text, never expanding it here.
# shellcheck disable=SC2016
sed -e 's/--argjson w_out "\${SPEND_WEIGHT_OUTPUT:-0}"/--argjson w_out '"$W_OUT"'/' \
  "$EMIT" > "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
AFTER="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT="$OVERRIDE_W_OUT" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "AFTER tamper (weight hardcoded to today's default): the env override no longer has any effect — proves inheritance was real" "$expected_default" "$AFTER"
cp "$EMIT" "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
RESTORED="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT="$OVERRIDE_W_OUT" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "RESTORED: the override is honored again" "$expected_override" "$RESTORED"

echo "── 17. MUTATION: session_id is the RAW, untruncated join key, not a truncated stamp ──"
BEFORE_SESS="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID="$LONGSESS" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source unavailable \
  --outcome-ref issue:1 --print-only | jq -r '.session_id')"
check_eq "BEFORE tamper: the full untruncated session id is carried" "$LONGSESS" "$BEFORE_SESS"
# Intentional: matching a literal 'session_id="${CLAUDE_CODE_SESSION_ID:-}"' in the source text, never expanding it here.
# shellcheck disable=SC2016
sed -e 's/session_id="\${CLAUDE_CODE_SESSION_ID:-}"/session_id="\${CLAUDE_CODE_SESSION_ID:-}"; session_id="\${session_id:0:8}"/' \
  "$EMIT" > "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
AFTER_SESS="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID="$LONGSESS" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source unavailable \
  --outcome-ref issue:1 --print-only | jq -r '.session_id')"
check_not "AFTER tamper (session id truncated to 8 chars): no longer matches the full raw id" \
  bash -c "[ '$AFTER_SESS' = '$LONGSESS' ]"
cp "$EMIT" "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
RESTORED_SESS="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID="$LONGSESS" \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source unavailable \
  --outcome-ref issue:1 --print-only | jq -r '.session_id')"
check_eq "RESTORED: full untruncated session id carried again" "$LONGSESS" "$RESTORED_SESS"

echo "── 18. doc-presence: the divergence from ADR 0020 is documented at the emit site ──"
check "emit-model-usage.sh documents requestId dedup as NOT inheritable / N/A" \
  grep -Fq 'requestId DEDUP' "$EMIT"
check "...and names the declared owner (the CLI envelope)" \
  grep -Fq 'DECLARED OWNER of this divergence is the CLI envelope' "$EMIT"
check "emit-model-usage.sh documents cache-class weighting as inherited via SPEND_WEIGHT_*" \
  grep -Fq 'cache-class WEIGHTING' "$EMIT"
# Intentional: matching a literal '$here/...' bash expansion inside
# emit-model-usage.sh's own source, never expanding it here.
# shellcheck disable=SC2016
check "emit-model-usage.sh sources build.config.sh (never a duplicated weight literal)" \
  grep -Fq 'source "$here/build/build.config.sh"' "$EMIT"
check "docs/features/model-comparison.md (this module's own feature doc) also documents the dedup-inapplicable correction" \
  grep -Fq 'inapplicable' "$MODELCMP_MD"
check "emit-model-usage.sh documents the ADR 0028 no-host divergence" \
  grep -Fq 'ADR 0028 divergence: no host' "$EMIT"

echo "── 19. discoverability: the new stream is documented in docs/features/telemetry.md ──"
[ -f "$TELEMETRY_MD" ] || { echo "FATAL: telemetry.md not found at $TELEMETRY_MD" >&2; exit 1; }
check "telemetry.md lists the model-usage stream" grep -Fq 'model-usage' "$TELEMETRY_MD"
check "telemetry.md's stream entry names the record's core fields" \
  grep -Fq 'seat' "$TELEMETRY_MD"

echo "── 20. quality-gates.sh registration: both new gates are wired at the assigned anchor ──"
QG="$REPO/scripts/quality-gates.sh"
[ -f "$QG" ] || { echo "FATAL: quality-gates.sh not found at $QG" >&2; exit 1; }
check "quality-gates.sh registers the validator gate" \
  grep -Fq 'workflows/scripts/validate-model-usage-emit.sh' "$QG"
check "quality-gates.sh registers the test-suite gate" \
  grep -Fq 'workflows/scripts/tests/test_model_usage_emit.sh' "$QG"
check "the new gates sit immediately after the validate-issue-touch-emit anchor" bash -c "
  awk '/make validate-issue-touch-emit/{f=1; n=0} f{n++; if (/validate-model-usage-emit\\.sh/) {print \"found\"; exit} if (n>15) exit}' '$QG' | grep found >/dev/null
"

echo "── 21. kernel-manifest.txt classifies both new files as kernel ──"
KM="$REPO/workflows/scripts/kernel/kernel-manifest.txt"
[ -f "$KM" ] || { echo "FATAL: kernel-manifest.txt not found at $KM" >&2; exit 1; }
check "kernel-manifest.txt classifies emit-model-usage.sh" \
  grep -Fq 'kernel workflows/scripts/emit-model-usage.sh' "$KM"
check "kernel-manifest.txt classifies validate-model-usage-emit.sh" \
  grep -Fq 'kernel workflows/scripts/validate-model-usage-emit.sh' "$KM"

echo "── 22. BLOCKING 1: a trailing value-taking flag does NOT hang (bounded-timeout proof) ──"
HANG_TMP="$TMP/hangtest"
mkdir -p "$HANG_TMP"
hang_check() { # <desc> <secs> <want_rc> <cmd...>
  local d="$1" secs="$2" want_rc="$3"; shift 3
  local rc
  run_with_timeout "$secs" "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 137 ]; then
    bad "$d" "TIMED OUT (hung) after ${secs}s — rc=137"
  elif [ "$rc" -eq "$want_rc" ]; then
    ok "$d (bounded, rc=$rc as expected)"
  else
    bad "$d" "did not hang, but rc=$rc (wanted $want_rc)"
  fi
}
# emit-model-usage.sh: WARN-DON'T-DROP contract -> always exits 0.
hang_check "emit: trailing --seat does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat
hang_check "emit: trailing --model does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --model
hang_check "emit: trailing --usage-source does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source
hang_check "emit: trailing --outcome-ref does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source unavailable --outcome-ref
hang_check "emit: trailing --provider does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider
hang_check "emit: trailing --input-tokens does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens
hang_check "emit: trailing --output-tokens does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 1 --output-tokens
hang_check "emit: trailing --cache-read-tokens does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 1 --output-tokens 1 --cache-read-tokens
hang_check "emit: trailing --cache-creation-tokens does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 1 --output-tokens 1 --cache-read-tokens 0 --cache-creation-tokens
hang_check "emit: trailing --duration-ms does not hang (the acceptance-named case)" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source unavailable --outcome-ref issue:1 --duration-ms
hang_check "emit: trailing --repo does not hang" 8 0 env MODEL_USAGE_RAW_DIR="$HANG_TMP" bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source unavailable --outcome-ref issue:1 --repo
# validate-model-usage-emit.sh: FAIL-CLOSED discipline -> CANNOT EVALUATE, exit 1.
hang_check "validator: trailing --file does not hang (the acceptance-named case)" 8 1 bash "$LINT" --file

echo "── 22b. advisory 9c: a value that looks like another flag is rejected, not silently consumed ──"
mkdir -p "$TMP/flaglike"
FLAGLIKE_ERR="$(MODEL_USAGE_RAW_DIR="$TMP/flaglike" CLAUDE_CODE_SESSION_ID=s bash "$EMIT" --seat --model foo --usage-source unavailable --outcome-ref issue:1 2>&1 >/dev/null)"
check "names the flag-like-value rejection, not consuming --model as the seat" bash -c \
  "grep -F -- \"requires a value, got flag-like '--model'\" <<<\"\$1\" >/dev/null" _ "$FLAGLIKE_ERR"
FLAGLIKE_OUT="$(MODEL_USAGE_RAW_DIR="$TMP/flaglike" CLAUDE_CODE_SESSION_ID=s bash "$EMIT" --seat x --model foo --usage-source unavailable --outcome-ref issue:1 --print-only)"
check_eq "sanity: a normal (non-flag-like) value is still consumed as intended" "foo" "$(printf '%s' "$FLAGLIKE_OUT" | jq -r '.model')"

echo "── 23. BLOCKING 3: an unreadable raw-lake directory CANNOT EVALUATE, never silently OK ──"
UNREADABLE_DIR="$TMP/unreadable-lake"
mkdir -p "$UNREADABLE_DIR"
add_exit_cleanup "chmod 700 '$UNREADABLE_DIR' 2>/dev/null || true"
chmod 000 "$UNREADABLE_DIR"
UNREADABLE_ERR="$(MODEL_USAGE_RAW_DIR="$UNREADABLE_DIR" bash "$LINT" 2>&1)"
UNREADABLE_RC=$?
chmod 700 "$UNREADABLE_DIR"   # inline restore — the EXIT trap above is the belt-and-suspenders backstop
check_eq "an unreadable raw dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$UNREADABLE_RC"
check "...says CANNOT EVALUATE, never OK" bash -c \
  "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\" && ! grep -Fq 'validate-model-usage-emit: OK' <<<\"\$1\"" _ "$UNREADABLE_ERR"

echo "── 24. BLOCKING 3 / A6: a CLOSED stdin ('--file -') CANNOT EVALUATE, never silently OK ──"
# This is precisely the case that survived the prior mutation pass (A6): the
# '--file -' stdin seam had zero fixture coverage, so a validator that read
# "line 291: 0: Bad file descriptor" then printed OK on a closed stdin went
# undetected.
CLOSED_ERR="$(bash "$LINT" --file - <&- 2>&1)"
CLOSED_RC=$?
check_eq "closed stdin: exit 1 (CANNOT EVALUATE), not 0" "1" "$CLOSED_RC"
check "...says CANNOT EVALUATE, never OK" bash -c \
  "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\" && ! grep -Fq 'validate-model-usage-emit: OK' <<<\"\$1\"" _ "$CLOSED_ERR"

echo "── 25. advisory A6: the documented '--file -' stdin seam has real fixture coverage (good/bad) ──"
check "a good record piped on stdin: OK" bash -c \
  "MODEL_USAGE_RAW_DIR='$TMP/l1' bash '$EMIT' --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 1 --output-tokens 1 --cache-read-tokens 0 --cache-creation-tokens 0 --outcome-ref issue:1 --print-only | bash '$LINT' --file -"
check_not "garbage piped on stdin: FAILS" bash -c "printf 'not json\n' | bash '$LINT' --file -"

echo "── 26. advisory A4: a DIRECTORY matching the glob is skipped cleanly (no set -u crash) ──"
A4_DIR="$TMP/a4-lake"
mkdir -p "$A4_DIR/model-usage-2099-01.jsonl"   # a directory, not a file, matching the glob pattern
A4_OUT="$(MODEL_USAGE_RAW_DIR="$A4_DIR" bash "$LINT" 2>&1)"
A4_RC=$?
check_eq "a directory matching the glob: exits 0 cleanly (nothing real to scan)" "0" "$A4_RC"
check "...no bash 'unbound variable' trace leaked" bash -c "! grep -Fiq 'unbound variable' <<<\"\$1\"" _ "$A4_OUT"

echo "── 27. advisory A5: FAIL line numbers are per-FILE (reset), not a running total across files ──"
A5_DIR="$TMP/a5-lake"
mkdir -p "$A5_DIR"
printf '%s\n%s\n%s\n' \
  '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:1"}' \
  '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:2"}' \
  '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-turbo-1","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:3"}' \
  > "$A5_DIR/model-usage-2026-06.jsonl"
printf '%s\n' \
  '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-turbo-2","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:4"}' \
  > "$A5_DIR/model-usage-2026-07.jsonl"
A5_OUT="$(MODEL_USAGE_RAW_DIR="$A5_DIR" bash "$LINT" 2>&1)"
check "file 1's bad record is cited at ITS OWN line 3" bash -c \
  "grep -F 'model-usage-2026-06.jsonl:3' <<<\"\$1\" >/dev/null" _ "$A5_OUT"
check "file 2's bad record is cited at ITS OWN line 1 (reset per file)" bash -c \
  "grep -F 'model-usage-2026-07.jsonl:1' <<<\"\$1\" >/dev/null" _ "$A5_OUT"
check "...and NOT at a running-total line 4 across files (the bug this advisory fixes)" bash -c \
  "! grep -F 'model-usage-2026-07.jsonl:4' <<<\"\$1\" >/dev/null" _ "$A5_OUT"

echo "── 28. advisory A9a: no hardcoded \$HOME/dev/foundation fallback path remains in either script ──"
check "emit-model-usage.sh: the old foreign-path-guessing fallback code is gone" \
  bash -c "! grep -Fq 'echo \"\$HOME/dev/foundation\"' '$EMIT'"
check "validate-model-usage-emit.sh: the old foreign-path-guessing fallback code is gone" \
  bash -c "! grep -Fq 'echo \"\$HOME/dev/foundation\"' '$LINT'"
check "emit-model-usage.sh instead warns-and-drops when the repo root can't be resolved" \
  grep -Fq 'no fallback path guessed' "$EMIT"
check "validate-model-usage-emit.sh instead CANNOT EVALUATEs when the repo root can't be resolved" \
  grep -Fq 'no fallback path guessed' "$LINT"

echo "── 29. advisory A9b: --help prints the FULL header, not truncated mid-sentence ──"
HELP_OUT="$(bash "$EMIT" --help)"
check "help output names the WARN-DON'T-DROP contract (the single most important thing a spawn-site author needs)" \
  bash -c "grep -Fq \"WARN, DON'T DROP\" <<<\"\$1\"" _ "$HELP_OUT"
check "help output reaches the FINAL header line" \
  bash -c "grep -Fq 'macOS dev shell + Linux CI' <<<\"\$1\"" _ "$HELP_OUT"
check "help output excludes the shebang line" \
  bash -c "! grep -Fq '#!/usr/bin/env bash' <<<\"\$1\"" _ "$HELP_OUT"
check "help output does not run past the header into executable code" \
  bash -c "! grep -Fq 'set -uo pipefail' <<<\"\$1\"" _ "$HELP_OUT"

echo "── 30. advisory A7: weighted_units' retune-epoch caveat is documented ──"
check "emit-model-usage.sh documents weighted_units as comparable only within a SPEND_WEIGHT_* retune epoch" \
  grep -Fq 'retune epoch' "$EMIT"
check "...and names tokens as the durable, retune-independent figure" \
  grep -Fq 'is the durable' "$EMIT"

echo "── 31. spawn-site coverage (temperloop#1255): the REAL checkout wires A7/A8/A9 ──"
check "the validator passes coverage against the real checkout (default scan dir)" \
  bash "$LINT"
LINT_REAL_OUT="$(bash "$LINT" 2>&1)"
check "...names A7 (pipeline-drive-safe) as wired" \
  bash -c "grep -Fq 'A7 pipeline-drive.sh safe-tier driver wires model_usage_emit_from_envelope \"pipeline-drive-safe\"' <<<\"\$1\"" _ "$LINT_REAL_OUT"
check "...names A8 (pipeline-drive-merge) as wired" \
  bash -c "grep -Fq 'A8 pipeline-drive.sh merge-tier driver wires model_usage_emit_from_envelope \"pipeline-drive-merge\"' <<<\"\$1\"" _ "$LINT_REAL_OUT"
check "...names A9 (retro-judge) as wired" \
  bash -c "grep -Fq 'A9 retro-judge spawn wires model_usage_emit_from_envelope \"retro-judge\"' <<<\"\$1\"" _ "$LINT_REAL_OUT"

echo "── 32. spawn-site coverage: the exclusion list names every un-emittable seat WITH the spike's reason ──"
for seat_id in A1 A2 A3 A4 A5 A6 B1 B2 C1 C2 C3; do
  check "exclusion list names $seat_id" \
    bash -c "grep -Fq 'excluded $seat_id ' <<<\"\$1\"" _ "$LINT_REAL_OUT"
done
check "A1/A3/A4 carry the .mjs no-usage/no-join-key reason" \
  bash -c "grep -F 'excluded A1 ' <<<\"\$1\" | grep -F 'no legal join key' >/dev/null" _ "$LINT_REAL_OUT"
check "A5/A6 additionally carry the cannot-source-shell-config reason" \
  bash -c "grep -F 'excluded A5 ' <<<\"\$1\" | grep -F 'unable to source shell config' >/dev/null" _ "$LINT_REAL_OUT"
check "B1 carries the session-granularity/no-seat/no-outcome-ref reason" \
  bash -c "grep -F 'excluded B1 ' <<<\"\$1\" | grep -F 'no seat name and no outcome ref' >/dev/null" _ "$LINT_REAL_OUT"
check "B2 carries the harness-native agent-frontmatter reason" \
  bash -c "grep -F 'excluded B2 ' <<<\"\$1\" | grep -F 'no kernel code in the spawn path' >/dev/null" _ "$LINT_REAL_OUT"
check "C1/C2/C3 carry the --output-format text / #1264 reason" \
  bash -c "grep -F 'excluded C1 ' <<<\"\$1\" | grep -F 'temperloop#1264' >/dev/null" _ "$LINT_REAL_OUT"

echo "── 33. MUTATION: removing the A7 emit call FAILS coverage; restoring it passes again ──"
reset_covr
check "BEFORE tamper: coverage fixture passes" bash "$LINT" --scan-dir "$COVR"
python3 - "$COVR/pipeline-drive.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = '''    model_usage_emit_from_envelope "pipeline-drive-safe" "$PIPELINE_DRIVE_MODEL" \\
      "$(_outcome_ref_for_batch "$acts_b" "$b")" "$(_board_repo "$b" 2>/dev/null || true)" \\
      "$MODEL_USAGE_EMIT" <<<"$driver_out"
'''
assert needle in c, "A7 emit-call needle not found in fixture — production wiring text drifted"
open(p, "w").write(c.replace(needle, ""))
PYEOF
check_not "AFTER tamper (A7 emit call removed): coverage WRONGLY-passing case is now caught — coverage FAILS" \
  bash "$LINT" --scan-dir "$COVR"
check "...names A7 specifically" bash -c \
  "bash '$LINT' --scan-dir '$COVR' 2>&1 | grep -F 'A7 pipeline-drive.sh safe-tier driver' | grep -F FAIL >/dev/null"
reset_covr
check "RESTORED: coverage passes again" bash "$LINT" --scan-dir "$COVR"

echo "── 34. MUTATION: removing the A8 emit call FAILS coverage; restoring it passes again ──"
reset_covr
python3 - "$COVR/pipeline-drive.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = '''    model_usage_emit_from_envelope "pipeline-drive-merge" "$PIPELINE_DRIVE_MERGE_MODEL" \\
      "$(_outcome_ref_for_batch "$acts_b" "$b")" "$(_board_repo "$b" 2>/dev/null || true)" \\
      "$MODEL_USAGE_EMIT" <<<"$merge_out"
'''
assert needle in c, "A8 emit-call needle not found in fixture — production wiring text drifted"
open(p, "w").write(c.replace(needle, ""))
PYEOF
check_not "AFTER tamper (A8 emit call removed): coverage FAILS" bash "$LINT" --scan-dir "$COVR"
check "...names A8 specifically" bash -c \
  "bash '$LINT' --scan-dir '$COVR' 2>&1 | grep -F 'A8 pipeline-drive.sh merge-tier driver' | grep -F FAIL >/dev/null"
reset_covr
check "RESTORED: coverage passes again" bash "$LINT" --scan-dir "$COVR"

echo "── 35. MUTATION: removing the A9 (retro-judge) emit call FAILS coverage; restoring it passes again ──"
reset_covr
python3 - "$COVR/pipeline-retro-judge-spawn.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = '''model_usage_emit_from_envelope "retro-judge" "$model" "issue:board-$board" "" \\
  "$MODEL_USAGE_EMIT" <<<"$out"
'''
assert needle in c, "A9 emit-call needle not found in fixture — production wiring text drifted"
open(p, "w").write(c.replace(needle, ""))
PYEOF
check_not "AFTER tamper (A9 emit call removed): coverage FAILS" bash "$LINT" --scan-dir "$COVR"
check "...names A9 specifically" bash -c \
  "bash '$LINT' --scan-dir '$COVR' 2>&1 | grep -F 'A9 retro-judge spawn' | grep -F FAIL >/dev/null"
reset_covr
check "RESTORED: coverage passes again" bash "$LINT" --scan-dir "$COVR"

echo "── 36. MUTATION: a NEWLY ADDED, unwired spawn site FAILS coverage (the generic forward net) ──"
reset_covr
check "BEFORE: coverage fixture passes with no extra file" bash "$LINT" --scan-dir "$COVR"
cat > "$COVR/pipeline-drive-experimental.sh" <<'EOF'
#!/usr/bin/env bash
# a hypothetical future driver spawning claude the same captured-envelope way
set -uo pipefail
out="$(claude -p "/do-something" --model claude-sonnet-5 --output-format json)"
echo "$out"
EOF
check_not "AFTER: a brand-new unwired --output-format json spawn site FAILS coverage — never enumerated by name, caught generically" \
  bash "$LINT" --scan-dir "$COVR"
check "...names the new file specifically, not one of the three known seats" bash -c \
  "bash '$LINT' --scan-dir '$COVR' 2>&1 | grep -F 'pipeline-drive-experimental.sh' | grep -F 'unwired spawn site' >/dev/null"
reset_covr
check "RESTORED (file removed): coverage passes again" bash "$LINT" --scan-dir "$COVR"

echo "── 37. advisory: a comment-only mention never counts as wiring (the grep-in-a-comment trap) ──"
reset_covr
python3 - "$COVR/pipeline-drive.sh" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out = []
for l in lines:
    if 'model_usage_emit_from_envelope "pipeline-drive-safe"' in l:
        out.append("    # " + l.lstrip())
    else:
        out.append(l)
open(p, "w").writelines(out)
PYEOF
check_not "A7's emit call commented out (string SURVIVES only in a comment): coverage still FAILS — a comment is not code" \
  bash "$LINT" --scan-dir "$COVR"
reset_covr
check "RESTORED: coverage passes again" bash "$LINT" --scan-dir "$COVR"

echo "── 38. FAIL-CLOSED: an absent/unreadable --scan-dir CANNOT EVALUATE, never silently OK ──"
ABSENT_ERR="$(bash "$LINT" --scan-dir "$TMP/does-not-exist-anywhere" 2>&1)"
ABSENT_RC=$?
check_eq "an absent scan dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$ABSENT_RC"
check "...says CANNOT EVALUATE, never OK" bash -c \
  "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\" && ! grep -Fq 'validate-model-usage-emit: OK' <<<\"\$1\"" _ "$ABSENT_ERR"

UNREADABLE_SCAN="$TMP/unreadable-scan"
mkdir -p "$UNREADABLE_SCAN"
# Inline restore only (no add_exit_cleanup layering here): section 23 above
# already registered one EXIT-trap layer for its own UNREADABLE_DIR, and
# add_exit_cleanup's trap-string reconstruction is not safely re-entrant for
# a THIRD-plus layer once the accumulated trap text itself contains quoted
# paths (observed: a second call corrupts the composed trap string into an
# unparseable one, "unexpected EOF while looking for matching `'"). The
# inline chmod 700 immediately below is what actually matters for
# correctness here — the EXIT-trap layering above is optional
# belt-and-suspenders this section does not need a second copy of.
chmod 000 "$UNREADABLE_SCAN"
UNREADABLE_SCAN_ERR="$(bash "$LINT" --scan-dir "$UNREADABLE_SCAN" 2>&1)"
UNREADABLE_SCAN_RC=$?
chmod 700 "$UNREADABLE_SCAN"
check_eq "an unreadable scan dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$UNREADABLE_SCAN_RC"
check "...says CANNOT EVALUATE, never OK" bash -c \
  "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\" && ! grep -Fq 'validate-model-usage-emit: OK' <<<\"\$1\"" _ "$UNREADABLE_SCAN_ERR"

echo "── 39. FAIL-CLOSED: an empty --scan-dir (no build files at all) is a genuine FAIL, not CANNOT EVALUATE ──"
# Distinguishes "cannot evaluate" (dir missing/unreadable, above) from "DID
# evaluate and the expected files are genuinely absent" — the latter is a
# real coverage gap (the named seats' files don't exist there) and must FAIL
# with a clear reason, not silently pass as "nothing to check".
EMPTY_SCAN="$TMP/empty-scan"
mkdir -p "$EMPTY_SCAN"
check_not "an empty scan dir (missing pipeline-drive.sh/pipeline-retro-judge-spawn.sh): coverage FAILS" \
  bash "$LINT" --scan-dir "$EMPTY_SCAN"
check "...names the missing file, not a generic/silent failure" bash -c \
  "bash '$LINT' --scan-dir '$EMPTY_SCAN' 2>&1 | grep -F 'expected file is missing' >/dev/null"

echo "── 40. BLOCKING 1 class: a trailing --scan-dir does not hang (bounded-timeout proof) ──"
hang_check "validator: trailing --scan-dir does not hang" 8 1 bash "$LINT" --scan-dir

echo "── 41. advisory 9c class: a --scan-dir value that looks like another flag is rejected ──"
SCANDIR_FLAGLIKE_ERR="$(bash "$LINT" --scan-dir --file 2>&1)"
check "names the flag-like-value rejection" bash -c \
  "grep -F -- \"--scan-dir requires a value, got flag-like '--file'\" <<<\"\$1\" >/dev/null" _ "$SCANDIR_FLAGLIKE_ERR"

echo "── 42. discoverability: model-usage-envelope.sh documents the shared extraction and its fail-open contract ──"
check "the shared lib documents WHICH three seats source it (A7/A8/A9)" \
  grep -Fq 'A7' "$ENVELOPE_LIB"
check "...and its fail-open contract" \
  grep -Fq 'FAIL-OPEN' "$ENVELOPE_LIB"
check "...and the deliberate anthropic-vs-firstParty provider distinction" \
  grep -Fq 'firstParty' "$ENVELOPE_LIB"
check "pipeline-drive.sh sources the shared lib (never a re-implemented copy)" \
  grep -Fq 'model-usage-envelope.sh' "$PIPELINE_DRIVE_SH"
check "pipeline-retro-judge-spawn.sh sources the shared lib (never a re-implemented copy)" \
  grep -Fq 'model-usage-envelope.sh' "$RETRO_JUDGE_SPAWN_SH"

echo "── 43. quality-gates.sh: no separate gate line was needed — the existing entries already cover this file ──"
QG2="$REPO/scripts/quality-gates.sh"
check "quality-gates.sh still registers exactly the validator + this test suite for model-usage (no drift)" \
  bash -c "grep -Fq 'workflows/scripts/validate-model-usage-emit.sh' '$QG2' && grep -Fq 'workflows/scripts/tests/test_model_usage_emit.sh' '$QG2'"

echo "── 44. MUTATION (temperloop#1370): the exec-redirect fix is SCOPED — stderr written after the successful open survives; a bare exec swallows it ──"
# The defect: `exec 3<... 2>/dev/null` with NO command word applies its
# redirects PERMANENTLY to the current shell once the open succeeds — so
# every stderr write for the REST OF THE SCRIPT silently vanishes. Asserting
# only "still exits 0" would pass identically whether the bug is present or
# not (BLOCKING per the acceptance criteria) — this section instead asserts
# the property the bare form actually destroys: a diagnostic written AFTER
# the successful open must still reach stderr.
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
# Inject a marker stderr write immediately after the successful-open block
# (right where the issue says "any stderr write added after that line, by
# anyone, at any time, would disappear" under the bare form) — anchored on
# the unique `exit 1\n  fi\n  lineno=0` text so this only matches the exact
# post-open site, not some other `fi`.
python3 - "$FIXR/workflows/scripts/validate-model-usage-emit.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = "    exit 1\n  fi\n  lineno=0\n"
assert c.count(needle) == 1, "post-open anchor not found exactly once — production text drifted"
marker = "    exit 1\n  fi\n  echo \"MARKER-STDERR-AFTER-OPEN\" >&2\n  lineno=0\n"
open(p, "w").write(c.replace(needle, marker))
PYEOF
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
FIXED_ERR="$(bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl" 2>&1 1>/dev/null)"
check "WITH the scoped fix ({ exec 3<...; } 2>/dev/null): a stderr write after the successful open IS visible" \
  bash -c "grep -Fq 'MARKER-STDERR-AFTER-OPEN' <<<\"\$1\"" _ "$FIXED_ERR"
# Tamper: revert ONLY the exec line to the original bare (buggy) form, on top
# of the marker-carrying fixture above — reproducing temperloop#1370 exactly.
# Done via python3 (not sed) to avoid fragile shell/sed escaping around the
# literal `{`/`}`/`$` characters in the pattern — matches this suite's own
# established convention for exact-text source mutations.
python3 - "$FIXR/workflows/scripts/validate-model-usage-emit.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
scoped = 'if ! { exec 3< "$src"; } 2>/dev/null; then'
bare = 'if ! exec 3< "$src" 2>/dev/null; then'
assert c.count(scoped) == 1, "scoped exec line not found exactly once — production text drifted"
open(p, "w").write(c.replace(scoped, bare))
PYEOF
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "sanity: the tamper actually reproduced the bare form (no scoping braces left)" \
  bash -c "! grep -Fq '{ exec 3< \"\$src\"; }' '$FIXR/workflows/scripts/validate-model-usage-emit.sh'"
BARE_ERR="$(bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl" 2>&1 1>/dev/null)"
BARE_RC=$?
check_eq "AFTER tamper (bare exec reintroduced): the script still exits 0 — this is exactly why an exit-code-only check cannot discriminate the bug" \
  "0" "$BARE_RC"
check_not "AFTER tamper (bare exec reintroduced): the SAME marker write is now SWALLOWED — proves the check is genuinely load-bearing" \
  bash -c "grep -Fq 'MARKER-STDERR-AFTER-OPEN' <<<\"\$1\"" _ "$BARE_ERR"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "RESTORED: fixture copy (pristine, no marker) passes cleanly again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl"

echo "── 44b. temperloop#1343: the python3 invocation COUNT stays flat regardless of record count ──"
# The acceptance bar for a fork-count fix in this repo is counting forks
# directly (commit 9e542a4, temperloop#968) — wall-clock alone is gameable by
# a chunked-but-not-fully-batched rewrite that still looks flat at small N.
# So this shadows `python3` on PATH with a counting shim that execs the REAL
# python3 (found before the shim is installed) — behavior is unchanged, but
# every invocation is now tallied.
REAL_PYTHON3="$(command -v python3)"
[ -n "$REAL_PYTHON3" ] || { echo "FATAL: could not resolve a real python3 on PATH" >&2; exit 1; }
COUNT_DIR="$TMP/python3-count"
mkdir -p "$COUNT_DIR/bin"
cat > "$COUNT_DIR/bin/python3" <<SHIM
#!/usr/bin/env bash
echo x >> "$COUNT_DIR/calls"
exec "$REAL_PYTHON3" "\$@"
SHIM
chmod +x "$COUNT_DIR/bin/python3"

# count_python3_calls <n-records> -> sets CALL_COUNT and LAKE_DIR
count_python3_calls() {
  local n="$1"
  local dir="$TMP/lake-$n"
  mkdir -p "$dir"
  # printf's format string RECYCLES over extra positional args (one %d per
  # record), and `seq` supplies those args in ONE word-split — this builds
  # an n-record synthetic lake with a single printf builtin call, not an
  # n-iteration bash loop, so lake GENERATION itself stays cheap even at
  # n=10000 (generation cost is test setup, not the thing being measured).
  printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:%d"}\n' \
    $(seq 0 $((n - 1))) > "$dir/model-usage-2026-08.jsonl"
  rm -f "$COUNT_DIR/calls"
  MODEL_USAGE_LAST_OUT="$(MODEL_USAGE_RAW_DIR="$dir" PATH="$COUNT_DIR/bin:$PATH" bash "$LINT" 2>&1)"
  CALL_COUNT="$(wc -l < "$COUNT_DIR/calls" 2>/dev/null | tr -d ' ')"
  [ -z "$CALL_COUNT" ] && CALL_COUNT=0
  LAKE_DIR="$dir"
}

count_python3_calls 1
CALLS_1="$CALL_COUNT"
check "sanity: at least one python3 call happened for a 1-record lake" bash -c "[ '$CALLS_1' -ge 1 ]"

# 10,000 records — the exact scale temperloop#1343 measured (~28ms/record of
# pure fork/exec overhead, ~5 minutes added to a local `make gates`).
count_python3_calls 10000
CALLS_10K="$CALL_COUNT"
check_eq "the validator genuinely processed all 10000 records (not silently truncated)" \
  "Checked 1 file(s), 10000 record(s)." "$(printf '%s\n' "$MODEL_USAGE_LAST_OUT" | grep -F 'Checked ')"
check_eq "python3 CALL COUNT is IDENTICAL between a 1-record and a 10,000-record lake — O(1) per file, not O(records)" \
  "$CALLS_1" "$CALLS_10K"

echo "── 45. sweep (temperloop#1370): no BARE permanent-redirect exec sites remain repo-wide, and the scoped forms are correctly recognized ──"
# BASE — widened per temperloop#1370 review (LOW): the original
# `exec [0-9]<` pattern could only ever see an INPUT redirect on a plain
# numeric fd. Two siblings carry the identical permanent-redirect hazard and
# were invisible to it: `exec 3> "$log" 2>/dev/null` (an OUTPUT redirect) and
# bash-4 `exec {fd}< "$f" 2>/dev/null` (a named descriptor). The tree is
# clean of both today (verified via this very sweep) — this widening is
# prophylactic on a guard already being edited.
EXEC_SWEEP_BASE_RE='exec ([0-9]+|\{[A-Za-z_][A-Za-z_0-9]*\})[<>][^;]*2>/dev/null'
# SCOPED (the exclusion) — MUST match ONLY the genuinely-correct shape:
# `{ exec <fd><op> ...; } 2>/dev/null`, where the group's OWN `;` closes
# BEFORE `}` and `2>/dev/null` sits OUTSIDE the group. This is deliberately
# narrower than "any line containing '{ exec '" (temperloop#1370 review,
# MEDIUM): that blanket filter was ALSO matching the single most likely way
# this bug returns — `{ exec 3< "$f" 2>/dev/null; }`, a half-remembered
# "wrap it in braces" that puts the redirect on the WRONG side of the closing
# brace. A `{ }` group only saves/restores fds for redirections applied TO
# THE GROUP; with none there, the bare exec's own `2>/dev/null` still lands
# on the current shell exactly as before scoping was ever added — proven by
# section 45b below (and empirically, live bash, in the review that found
# this). Requiring the `;` immediately before `}` is exactly what excludes
# that variant while still recognizing the real fix.
EXEC_SWEEP_SCOPED_RE='\{[[:space:]]*exec ([0-9]+|\{[A-Za-z_][A-Za-z_0-9]*\})[<>][^;]*;[[:space:]]*\}[[:space:]]*2>/dev/null'
# Also noted in the review: the OLD base pattern `exec [0-9]<[^;]*2>/dev/null`
# could never match a CORRECTLY scoped line anyway, because the correct form
# always carries a `;` before the redirect and `[^;]*` excludes it — so the
# old `grep -v '{ exec '` filter was doing no useful work on the real fix; its
# only live effect was creating the 45b hole. The widened base above has the
# same property (a genuinely-scoped line's `;` still stops `[^;]*` before
# `2>/dev/null` is reached), so EXEC_SWEEP_SCOPED_RE is retained as defense in
# depth, not because the base regex needs it to skip a real scoped line.
sweep_exec_hits() { # <dir> -- zero-echo dir-scoped sweep, shared by 45/45b/45c
  grep -rnE "$EXEC_SWEEP_BASE_RE" --include='*.sh' "$1" 2>/dev/null \
    | grep -v '/workflows/scripts/tests/' \
    | grep -v -E "$EXEC_SWEEP_SCOPED_RE" \
    | grep -v -E ':[0-9]+:[[:space:]]*#' || true
}
BARE_EXEC_HITS="$(sweep_exec_hits "$REPO")"
check_eq "zero remaining BARE permanent-redirect exec sites repo-wide (this file's own is now scoped)" "" "$BARE_EXEC_HITS"
check "the fixed line in validate-model-usage-emit.sh uses the scoped { exec 3< ...; } 2>/dev/null form" \
  grep -Fq '{ exec 3< "$src"; } 2>/dev/null' "$LINT"
check "model-comparison/tagging.sh already used the scoped form before this fix (the in-tree idiom this fix copies)" \
  grep -Fq '{ exec 3<"$src"; } 2>/dev/null' "$REPO/workflows/scripts/model-comparison/tagging.sh"

echo "── 45b. MUTATION (temperloop#1370 review, MEDIUM): the sweep is no longer blind to the inner-redirect variant '{ exec N< ... 2>/dev/null; }' ──"
SWEEP_FIX="$TMP/sweep-fixtures"
mkdir -p "$SWEEP_FIX"
cat > "$SWEEP_FIX/inner-redirect-bug.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
f="/nope-does-not-exist"
if ! { exec 3< "$f" 2>/dev/null; }; then
  echo "could not open" >&2
fi
EOF
# BEFORE: the PRIOR filter (blanket `grep -v '{ exec '`, hardcoded here
# exactly as it shipped, not re-derived) is blind to this file.
OLD_FILTER_HITS="$(grep -rn 'exec [0-9]<[^;]*2>/dev/null' --include='*.sh' "$SWEEP_FIX" 2>/dev/null \
  | grep -v '{ exec ' || true)"
check_eq "BEFORE (prior blanket '{ exec ' filter): the inner-redirect bug variant is INVISIBLE to the sweep — this was the hole" \
  "" "$OLD_FILTER_HITS"
# AFTER: the fixed filter (this section's own sweep_exec_hits) catches it.
NEW_FILTER_HITS="$(sweep_exec_hits "$SWEEP_FIX")"
check "AFTER (fixed filter, excludes only the genuinely-correct scoped shape): the same inner-redirect bug variant now TRIPS the sweep" \
  bash -c "grep -Fq 'inner-redirect-bug.sh' <<<\"\$1\"" _ "$NEW_FILTER_HITS"
# Regression guard: the fixed filter must NOT flag a genuinely-correct scoped
# form as a false positive (a sweep that cries wolf gets ignored).
cat > "$SWEEP_FIX/correctly-scoped.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
f="/nope-does-not-exist"
if ! { exec 3< "$f"; } 2>/dev/null; then
  echo "could not open" >&2
fi
EOF
CORRECT_HITS="$(sweep_exec_hits "$SWEEP_FIX" | grep 'correctly-scoped.sh' || true)"
check_eq "the fixed filter does NOT flag a genuinely-correct scoped form as a false positive" "" "$CORRECT_HITS"
rm -f "$SWEEP_FIX/inner-redirect-bug.sh" "$SWEEP_FIX/correctly-scoped.sh"

echo "── 45c. widened sweep coverage (temperloop#1370 review, LOW): output-fd and bash-4 named-descriptor exec variants are also caught ──"
cat > "$SWEEP_FIX/output-fd-bug.sh" <<'EOF'
#!/usr/bin/env bash
exec 3> "/tmp/does-not-matter-$$" 2>/dev/null
EOF
cat > "$SWEEP_FIX/named-fd-bug.sh" <<'EOF'
#!/usr/bin/env bash
exec {fd}< "/nope-does-not-exist" 2>/dev/null
EOF
WIDENED_HITS="$(sweep_exec_hits "$SWEEP_FIX")"
check "a bare OUTPUT-redirect exec (exec N> ... 2>/dev/null) is caught by the widened sweep" \
  bash -c "grep -Fq 'output-fd-bug.sh' <<<\"\$1\"" _ "$WIDENED_HITS"
check "a bare bash-4 NAMED-DESCRIPTOR exec (exec {fd}< ... 2>/dev/null) is caught by the widened sweep" \
  bash -c "grep -Fq 'named-fd-bug.sh' <<<\"\$1\"" _ "$WIDENED_HITS"
rm -f "$SWEEP_FIX/output-fd-bug.sh" "$SWEEP_FIX/named-fd-bug.sh"

echo "── 46. failure-branch coverage (temperloop#1370 review, LOW): a failed exec-open genuinely reaches stderr as CANNOT EVALUATE, rc=1 ──"
# Lines ~441-448 (the CANNOT EVALUATE arm) had zero fixture coverage, and
# this fix's own change altered that branch's observable output (BLOCKING per
# the review). Mutates ONLY the exec line's "$src" to a hardcoded nonexistent
# path — bypassing the earlier -f/-r existence checks entirely (which still
# see the real, valid $TMP/good.jsonl) so the failure is isolated to the open
# itself, exactly the seam this fix touches.
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
python3 - "$FIXR/workflows/scripts/validate-model-usage-emit.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = 'if ! { exec 3< "$src"; } 2>/dev/null; then'
assert c.count(needle) == 1, "scoped exec line not found exactly once — production text drifted"
broken = 'if ! { exec 3< "/tmp/temperloop-1370-does-not-exist-$$"; } 2>/dev/null; then'
open(p, "w").write(c.replace(needle, broken))
PYEOF
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
FAILOPEN_ERR="$(bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl" 2>&1 1>/dev/null)"
FAILOPEN_RC=$?
check_eq "a failed open exits 1 (fail-closed), never 0" "1" "$FAILOPEN_RC"
check "a failed open reaches stderr with the CANNOT EVALUATE — could not open message (the fail-closed contract this file's header advertises)" \
  bash -c "grep -Fq 'could not open' <<<\"\$1\"" _ "$FAILOPEN_ERR"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "RESTORED: fixture passes cleanly again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl"

echo "── 47. MUTATION (temperloop#1370 review, LOW): 'set +o posix' keeps the failed-open diagnostic visible under POSIXLY_CORRECT ──"
# exec is a POSIX special builtin: in posix mode a redirection error on it
# exits a NON-INTERACTIVE shell immediately, so the `if !` arm guarding the
# CANNOT EVALUATE message never runs. Narrow trigger (only when
# POSIXLY_CORRECT is set), fail-closed (rc stays 1 either way — this is a
# lost DIAGNOSTIC, never a lost failure), but INVISIBLE when it happens. Same
# "$src"-mutation technique as section 46, so this isolates the posix guard's
# own effect rather than any difference in how the failure is provoked.
#
# BASH-VERSION CAPABILITY PROBE (temperloop#1649). "a redirection error on a
# special builtin exits a non-interactive posix-mode shell" is a bash 4+
# behaviour. Bash 3.2 — the system /bin/bash on macOS, and therefore the `bash`
# that `scripts/quality-gates.sh` resolves to on the macos-latest runner — does
# NOT abort here: it falls into the `if !` arm and prints the diagnostic with or
# without the guard, so on 3.2 the guard is provably INERT and the strict
# "diagnostic is now lost" assertion below is simply false. That asymmetry made
# this one check the fifth red gate on seven consecutive nightly-macos runs.
#
# The fix is NOT to skip the check on macOS. It is to MEASURE the host shell's
# actual behaviour with a minimal reproduction of the exact production shape,
# and then assert the correct thing for that shell — BOTH branches assert, and
# the branch taken is printed, so nothing degrades silently:
#   * bash aborts (4+)     -> the guard MUST be load-bearing: tampering it away
#                             must LOSE the diagnostic (the original check).
#   * bash does not (3.2)  -> the guard MUST be inert: tampering it away must
#                             LEAVE the diagnostic intact. The inverse claim,
#                             equally falsifiable — a 3.2 that silently dropped
#                             the diagnostic would still fail this suite.
# Where the PRODUCTION guard's own discrimination is enforced: on the bash-4+
# leg. Deleting `set +o posix` from validate-model-usage-emit.sh takes this suite
# RED under bash 5.x (measured: `FAILED 1 of 195`) — and that is the ubuntu-only
# pre-merge `checks` gate, i.e. the leg that actually blocks a merge. On bash 3.2
# the same deletion is undetectable BECAUSE the guard genuinely does nothing
# there; asserting otherwise is what made this gate red for seven nights.
POSIX_PROBE="$TMP/posix-special-builtin-abort-probe.sh"
cat >"$POSIX_PROBE" <<'PROBEEOF'
set -uo pipefail
if ! { exec 3< "/tmp/temperloop-1649-does-not-exist-$$"; } 2>/dev/null; then
  echo DIAGNOSTIC_ARM_REACHED >&2
fi
PROBEEOF
POSIX_PROBE_ERR="$(POSIXLY_CORRECT=1 bash "$POSIX_PROBE" 2>&1 1>/dev/null || true)"
if [ -n "$POSIX_PROBE_ERR" ]; then
  POSIX_ABORTS_ON_SPECIAL_BUILTIN=0
else
  POSIX_ABORTS_ON_SPECIAL_BUILTIN=1
fi
echo "  probe  this bash ($(bash -c 'echo "$BASH_VERSION"')) aborts a posix-mode shell on a special-builtin redirection error: $([ "$POSIX_ABORTS_ON_SPECIAL_BUILTIN" -eq 1 ] && echo yes || echo 'no — guard is inert here, asserting the inverse')"

cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
python3 - "$FIXR/workflows/scripts/validate-model-usage-emit.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = 'if ! { exec 3< "$src"; } 2>/dev/null; then'
assert c.count(needle) == 1, "scoped exec line not found exactly once — production text drifted"
broken = 'if ! { exec 3< "/tmp/temperloop-1370-does-not-exist-$$"; } 2>/dev/null; then'
open(p, "w").write(c.replace(needle, broken))
PYEOF
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
POSIX_FIXED_ERR="$(POSIXLY_CORRECT=1 bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl" 2>&1 1>/dev/null)"
POSIX_FIXED_RC=$?
check_eq "WITH 'set +o posix' present: a failed open under POSIXLY_CORRECT=1 still exits 1" "1" "$POSIX_FIXED_RC"
check "WITH 'set +o posix' present: the CANNOT EVALUATE diagnostic still reaches stderr under POSIXLY_CORRECT=1 (not silently swallowed)" \
  bash -c "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\"" _ "$POSIX_FIXED_ERR"
# Tamper: remove the 'set +o posix' line (on top of the same broken-open
# fixture above) and confirm the diagnostic goes silent under
# POSIXLY_CORRECT=1 while rc is unchanged — fail-closed but invisible,
# exactly the review finding.
python3 - "$FIXR/workflows/scripts/validate-model-usage-emit.sh" <<'PYEOF'
import sys
p = sys.argv[1]
c = open(p).read()
needle = "set -uo pipefail\n"
assert needle in c, "set -uo pipefail line not found — production text drifted"
posix_line = [l for l in c.splitlines(True) if l.strip() == "set +o posix"]
assert len(posix_line) == 1, "set +o posix line not found exactly once — production text drifted"
open(p, "w").write(c.replace(posix_line[0], ""))
PYEOF
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
POSIX_TAMPER_ERR="$(POSIXLY_CORRECT=1 bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl" 2>&1 1>/dev/null)"
POSIX_TAMPER_RC=$?
check_eq "AFTER tamper (posix guard removed): rc is STILL 1 (fail-closed is unaffected)" "1" "$POSIX_TAMPER_RC"
if [ "$POSIX_ABORTS_ON_SPECIAL_BUILTIN" -eq 1 ]; then
  check_not "AFTER tamper (posix guard removed): the CANNOT EVALUATE diagnostic is now SILENTLY LOST under POSIXLY_CORRECT=1 — proves the guard is genuinely load-bearing" \
    bash -c "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\"" _ "$POSIX_TAMPER_ERR"
else
  check "AFTER tamper (posix guard removed): the CANNOT EVALUATE diagnostic SURVIVES on this bash — it does not abort a posix-mode shell on a special-builtin redirection error, so the guard is inert here (the inverse claim, asserted not skipped)" \
    bash -c "grep -Fq 'CANNOT EVALUATE' <<<\"\$1\"" _ "$POSIX_TAMPER_ERR"
fi
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "RESTORED: fixture passes cleanly again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/good.jsonl"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_model_usage_emit: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_model_usage_emit: OK — all %d checks passed\n' "$pass"
