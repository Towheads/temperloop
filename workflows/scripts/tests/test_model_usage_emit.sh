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

[ -f "$EMIT" ] || { echo "FATAL: emit-model-usage.sh not found at $EMIT" >&2; exit 1; }
[ -f "$LINT" ] || { echo "FATAL: validate-model-usage-emit.sh not found at $LINT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/model-usage-emit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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
# Default weights (build.config.sh): input=1, cache_read=0.1, cache_create=1.25, output=5.
# 100*1 + 200*0.1 + 10*1.25 + 50*5 = 100 + 20 + 12.5 + 250 = 382.5 -> floor 382.
check_eq "weighted_units matches the default SPEND_WEIGHT_* formula (floor(382.5)=382)" \
  "382" "$(printf '%s' "$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 --outcome-ref issue:1 --print-only)" | jq -r '.weighted_units')"
# Override ONE weight via env and confirm the computed figure actually moves —
# proof this is real sourcing from build.config.sh's `:=` seam, not a copied
# literal. SPEND_WEIGHT_OUTPUT overridden from 5 -> 100: 100 + 20 + 12.5 + 50*100=5000 -> 5132.5 -> floor 5132.
OVERRIDE_OUT="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT=100 \
  bash "$EMIT" --seat x --model claude-sonnet-5 --usage-source cli-envelope --provider anthropic \
  --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only)"
check_eq "an env override of SPEND_WEIGHT_OUTPUT changes weighted_units (genuine inheritance, not a hardcoded copy)" \
  "5132" "$(printf '%s' "$OVERRIDE_OUT" | jq -r '.weighted_units')"

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
chmod +x "$FIXR/workflows/scripts/"*.sh "$FIXR/workflows/scripts/model-comparison/allowlist.sh"

echo "── 11. MUTATION: presence-lint catches emit-model-usage.sh losing its exec bit ──"
check "fixture copy passes before tampering" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod -x "$FIXR/workflows/scripts/emit-model-usage.sh"
check_not "lint FAILS when emit-model-usage.sh loses its exec bit" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
check "restored: fixture copy passes again" bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh"

echo "── 12. MUTATION: the strict-parse NaN rejection is load-bearing ──"
# This fixture is otherwise a FULLY VALID, fully-compliant record (usage_source
# unavailable, tokens/provider/weighted_units all correctly null) plus one
# EXTRA field the schema-shape checks never look at, carrying NaN. No
# downstream type check (tokens.*, duration_ms, ...) touches this field, so
# this isolates the STRICT-PARSE step's own load-bearing-ness: if parse_constant
# is removed, NOTHING else in the validator can catch the corruption, and the
# record wrongly passes end to end. (The tokens.input placement used in
# section 9 above is a fine demonstration of the jq-vs-python TRAP, but is a
# poor mutation-test fixture: tokens.input also fails the separate
# isinstance(v, int) check, so removing parse_constant there does not, by
# itself, prove strict-parse was the thing catching it.)
printf '{"schema_version":"1","ts":"2026-08-08T12:00:00Z","session_id":null,"repo":null,"seat":"x","model":"claude-sonnet-5","provider":null,"usage_source":"unavailable","tokens":null,"weighted_units":null,"duration_ms":null,"outcome_ref":"issue:1","junk_unvalidated_field":NaN}\n' > "$TMP/nan-isolated.jsonl"
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

echo "── 15. MUTATION: the no-host check is load-bearing (ADR 0028) ──"
check_not "BEFORE tamper: fixture validator rejects a record carrying host" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
sed -e 's/if "host" in rec:/if False:/' "$LINT" > "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check "AFTER tamper (no-host check neutered): a record carrying host WRONGLY passes" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"
cp "$LINT" "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
chmod +x "$FIXR/workflows/scripts/validate-model-usage-emit.sh"
check_not "RESTORED: a record carrying host is rejected again" \
  bash "$FIXR/workflows/scripts/validate-model-usage-emit.sh" --file "$TMP/host.jsonl"

echo "── 16. MUTATION: cache-class weighting is sourced from build.config.sh, not hardcoded ──"
BEFORE="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT=100 \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "BEFORE tamper: SPEND_WEIGHT_OUTPUT=100 override moves weighted_units to 5132" "5132" "$BEFORE"
# Tamper: hardcode the output weight literal instead of sourcing it, breaking
# genuine inheritance from build.config.sh.
# Intentional: matching a literal '${SPEND_WEIGHT_OUTPUT:-0}' in the source text, never expanding it here.
# shellcheck disable=SC2016
sed -e 's/--argjson w_out "\${SPEND_WEIGHT_OUTPUT:-0}"/--argjson w_out 5/' \
  "$EMIT" > "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
AFTER="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT=100 \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "AFTER tamper (weight hardcoded to 5): the env override no longer has any effect (382, not 5132) — proves inheritance was real" "382" "$AFTER"
cp "$EMIT" "$FIXR/workflows/scripts/emit-model-usage.sh"
chmod +x "$FIXR/workflows/scripts/emit-model-usage.sh"
RESTORED="$(MODEL_USAGE_RAW_DIR="$TMP/l1" CLAUDE_CODE_SESSION_ID=s SPEND_WEIGHT_OUTPUT=100 \
  bash "$FIXR/workflows/scripts/emit-model-usage.sh" --seat x --model claude-sonnet-5 --usage-source cli-envelope \
  --provider anthropic --input-tokens 100 --output-tokens 50 --cache-read-tokens 200 --cache-creation-tokens 10 \
  --outcome-ref issue:1 --print-only | jq -r '.weighted_units')"
check_eq "RESTORED: the override is honored again (5132)" "5132" "$RESTORED"

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

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_model_usage_emit: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_model_usage_emit: OK — all %d checks passed\n' "$pass"
