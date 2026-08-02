#!/usr/bin/env bash
# Tests for workflows/scripts/pipeline-spend-report.sh and the kernel-side
# `tokens` report.d producer implementation at
# workflows/scripts/report-producers/tokens (temperloop#958; relocated out
# of .temperloop/report.d/tokens by temperloop#980
# "producer-kernel-side-relocation" -- that path is now a thin locator +
# exec shim, tested separately by
# bin/subcommands/tests/test_tokens_producer.sh).
#
# Synthetic transcript fixtures under a throwaway tmpdir, pointed at with
# --root. Zero network, zero reads of the operator's real ~/.claude corpus,
# never a mutation of anything outside the tmpdir.
#
# THE CENTRAL TEST is #1: DEDUPE BY requestId. Fixture `dedupe` carries one
# agent whose single API response is split across THREE transcript lines (a
# thinking block, a text block, a tool_use block), each repeating the SAME
# `usage` object — exactly the shape that inflated temperloop#953's corpus
# 2.16x when summed per line. The assertion is the undoubled number: 1 API
# call, one usage block's worth of tokens, whatever the line count. Every
# other check here is secondary to that one.
#
# Also asserted, because each is a documented trap the tool must keep
# encoded (see the script's own header):
#   - a line with NO requestId is NEVER deduped (nothing could prove it a repeat)
#   - the four cost weights come from settings, and no weight literal exists
#     in the script body (static grep — the structural proof, mirroring
#     workflows/scripts/lib/tests/test_token_sum.sh's privacy grep)
#   - no tool-call-parallelism metric is derived, ever (static grep)
#   - BSD dialect: no awk asort(), no `date -d`, no GNU `sed` label loops
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
BIN="$REPO_ROOT/workflows/scripts/pipeline-spend-report.sh"
PRODUCER="$REPO_ROOT/workflows/scripts/report-producers/tokens"
[ -f "$BIN" ] || { echo "FATAL: pipeline-spend-report.sh not found at $BIN" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <condition-command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s\n' "$desc"
  fi
}
check_eq() { # <desc> <expected> <actual>
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want %s, got %s)\n' "$desc" "$want" "$got"
  fi
}

# usage_line <requestId|-> <ts> <model> <cache_read> <cache_create> <output> <input> <block-type>
# Emits ONE transcript line in the real shape: an assistant message with a
# content array holding a single block, plus the repeated usage object. A
# requestId of `-` omits the field entirely (the un-dedupable case).
usage_line() {
  local rid="$1" ts="$2" model="$3" cr="$4" cc="$5" out="$6" inp="$7" blk="$8"
  if [ "$rid" = "-" ]; then
    jq -cn --arg ts "$ts" --arg m "$model" --arg b "$blk" \
      --argjson cr "$cr" --argjson cc "$cc" --argjson o "$out" --argjson i "$inp" \
      '{type:"assistant", timestamp:$ts, message:{role:"assistant", model:$m,
        content:[{type:$b}],
        usage:{cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$o, input_tokens:$i}}}'
  else
    jq -cn --arg r "$rid" --arg ts "$ts" --arg m "$model" --arg b "$blk" \
      --argjson cr "$cr" --argjson cc "$cc" --argjson o "$out" --argjson i "$inp" \
      '{type:"assistant", requestId:$r, timestamp:$ts, message:{role:"assistant", model:$m,
        content:[{type:$b}],
        usage:{cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$o, input_tokens:$i}}}'
  fi
}

mkagent() { # mkagent <root> <wf_id> <agent_id> ; then feed lines on stdin
  local root="$1" wf="$2" agent="$3"
  mkdir -p "$root/proj/sess/subagents/workflows/$wf"
  cat >"$root/proj/sess/subagents/workflows/$wf/agent-$agent.jsonl"
}

# Run the tool with the fixture's own weights/thresholds pinned by ENV (layer
# 2 of the six-layer ladder), so these assertions never move when the
# build.config.sh defaults are re-tuned. The DEFAULT-resolution path is
# exercised separately by check #3.
run() { # run <root> [extra args...]
  local root="$1"; shift
  SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
  SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=40 \
    bash "$BIN" --root "$root" --format json "$@"
}

# ===========================================================================
# 1. THE DEDUPE TEST — the single most important correctness property.
# ===========================================================================
# One agent. ONE API response, recorded as THREE transcript lines that each
# repeat the same usage block (thinking / text / tool_use — the real split).
# Summing per line would report 3 calls and 3x the tokens.
R1="$TMP/dedupe"
{
  usage_line req_A 2026-07-10T10:00:00.000Z claude-opus-5 1000 200 40 8 thinking
  usage_line req_A 2026-07-10T10:00:01.000Z claude-opus-5 1000 200 40 8 text
  usage_line req_A 2026-07-10T10:00:02.000Z claude-opus-5 1000 200 40 8 tool_use
} | mkagent "$R1" wf_dedupe-001 aaaa0000

J1="$(run "$R1")"
# 1 deduped call from 3 usage lines. units = 1000*0.1 + 200*1.25 + 40*5 + 8
#                                          =  100  +  250   +  200 + 8 = 558
check_eq "DEDUPE: 3 repeated usage lines collapse to 1 API call" \
  "1" "$(printf '%s' "$J1" | jq -r '.corpus.api_calls')"
check_eq "DEDUPE: the tool still SEES all 3 usage lines (so the collapse is real, not a read miss)" \
  "3" "$(printf '%s' "$J1" | jq -r '.corpus.usage_lines')"
check_eq "DEDUPE: total is the UNDOUBLED (untripled) 558, not 1674" \
  "558" "$(printf '%s' "$J1" | jq -r '.units_total')"
check_eq "DEDUPE: raw cache_read counted once (1000), not 3x" \
  "1000" "$(printf '%s' "$J1" | jq -r '.raw_tokens.cache_read')"
check_eq "DEDUPE: the naive per-line total is reported alongside, and IS 3x" \
  "1674" "$(printf '%s' "$J1" | jq -r '.corpus.units_undeduped')"
check "DEDUPE: the reported inflation factor is 3x (jq preserves the 3.00 literal, so compare numerically)" \
  bash -c "printf '%s' '$J1' | jq -e '.corpus.undeduped_inflation == 3' >/dev/null"
# Peak context surfaces through the worker profile; a floor of 1 admits this
# single-call agent so the number is assertable. One turn's ctx is
# cache_read + cache_create + input = 1000 + 200 + 8 — NEVER the sum of the
# three repeated lines (3624), which is the shape the dedupe bug produced.
check_eq "DEDUPE: peak context is one turn's ctx (1208), never a sum of repeats" \
  "1208" "$(SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
            SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 \
            bash "$BIN" --root "$R1" --format json | jq -r '.worker_profile.median_peak_context')"

# 1b. Two DISTINCT requestIds in the same agent are two calls — the dedupe
#     must not over-collapse.
R1B="$TMP/dedupe2"
{
  usage_line req_A 2026-07-10T10:00:00.000Z claude-opus-5 1000 200 40 8 thinking
  usage_line req_A 2026-07-10T10:00:01.000Z claude-opus-5 1000 200 40 8 text
  usage_line req_B 2026-07-10T10:00:05.000Z claude-opus-5 1000 200 40 8 text
} | mkagent "$R1B" wf_dedupe-002 bbbb0000
J1B="$(run "$R1B")"
check_eq "DEDUPE: two distinct requestIds stay two calls (no over-collapse)" \
  "2" "$(printf '%s' "$J1B" | jq -r '.corpus.api_calls')"
check_eq "DEDUPE: two distinct requestIds sum to 2x558" \
  "1116" "$(printf '%s' "$J1B" | jq -r '.units_total')"

# 1c. A line with NO requestId is never deduped — there is no key that could
#     prove it a repeat, so counting it once each is the honest read.
R1C="$TMP/norid"
{
  usage_line - 2026-07-10T10:00:00.000Z claude-opus-5 1000 200 40 8 text
  usage_line - 2026-07-10T10:00:01.000Z claude-opus-5 1000 200 40 8 text
} | mkagent "$R1C" wf_norid-003 cccc0000
J1C="$(run "$R1C")"
check_eq "DEDUPE: requestId-less lines are NOT deduped (2 lines -> 2 calls)" \
  "2" "$(printf '%s' "$J1C" | jq -r '.corpus.api_calls')"

# ===========================================================================
# 2. Cost weights are settings, not literals.
# ===========================================================================
W_DEFAULT="$(printf '%s' "$J1" | jq -r '.units_total')"
W_BUMPED="$(SPEND_WEIGHT_CACHE_READ=1 SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
            SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=40 \
            bash "$BIN" --root "$R1" --format json | jq -r '.units_total')"
check_eq "WEIGHTS: raising SPEND_WEIGHT_CACHE_READ 0.1->1 moves the total (100 -> 1000 on cache_read)" \
  "1458" "$W_BUMPED"
check "WEIGHTS: the two runs actually differ" test "$W_DEFAULT" != "$W_BUMPED"
check_eq "WEIGHTS: the weights in use are echoed back in the JSON" \
  "0.1" "$(printf '%s' "$J1" | jq -r '.weights.cache_read')"

# 2b. STATIC PROOF — no weight literal in the script body. The four weights
#     resolve with `:?` (never a `:=` default), so build.config.sh is the ONE
#     place any of these values exists. This grep is the mechanical backstop
#     for that structural claim (kernel CLAUDE.md § Named-setting convention).
check "STATIC: no SPEND_WEIGHT_* default literal (:= or :-) in the script body" \
  bash -c "! grep -E 'SPEND_(WEIGHT|MACHINERY|WORKER|TRANSCRIPT)[A-Z_]*:[=-]' '$BIN'"
check "STATIC: every SPEND_WEIGHT_* is resolved with the :? require form" \
  bash -c "test \"\$(grep -c 'SPEND_WEIGHT_[A-Z_]*:?' '$BIN')\" -ge 4"
check "STATIC: build.config.sh IS the place the weight literals live" \
  bash -c "grep -q 'SPEND_WEIGHT_CACHE_CREATE:=' '$REPO_ROOT/workflows/scripts/build/build.config.sh'"

# 2c. With NO config file reachable AND nothing exported, the `:?` form must
#     fail loudly and by name rather than fall back to a hidden literal —
#     that failure mode is the whole point of using `:?` over `:=`. Proved by
#     copying the script somewhere its `../../workflows/scripts/build/
#     build.config.sh` climb resolves to nothing.
mkdir -p "$TMP/noconfig/workflows/scripts"
cp "$BIN" "$TMP/noconfig/workflows/scripts/pipeline-spend-report.sh"
NOCFG_ERR="$(env -u SPEND_WEIGHT_INPUT -u SPEND_WEIGHT_CACHE_READ -u SPEND_WEIGHT_CACHE_CREATE \
                 -u SPEND_WEIGHT_OUTPUT -u SPEND_MACHINERY_MAX_CALLS -u SPEND_WORKER_PROFILE_MIN_CALLS \
                 -u SPEND_TRANSCRIPT_ROOT \
                 bash "$TMP/noconfig/workflows/scripts/pipeline-spend-report.sh" 2>&1; echo "rc=$?")"
check "WEIGHTS: with no config reachable, an unset weight is a NAMED failure" \
  bash -c "printf '%s' '$NOCFG_ERR' | grep -q 'SPEND_WEIGHT_INPUT is unset'"
check "WEIGHTS: ...and a non-zero exit, never a silent hidden default" \
  bash -c "! printf '%s' '$NOCFG_ERR' | grep -q 'rc=0'"

# ===========================================================================
# 3. Default resolution: with NO env overrides at all, the script must still
#    run — proving it reads build.config.sh rather than needing a caller to
#    pre-export everything.
# ===========================================================================
J3="$(bash "$BIN" --root "$R1" --format json)"
check "DEFAULTS: runs with zero env overrides (sources build.config.sh)" \
  bash -c "printf '%s' '$J3' | jq -e '.units_total' >/dev/null"
check_eq "DEFAULTS: build.config.sh's committed weights reproduce the same 558" \
  "558" "$(printf '%s' "$J3" | jq -r '.units_total')"

# ===========================================================================
# 4. Machinery vs item-worker classification, by deduped API-call count.
# ===========================================================================
R4="$TMP/classify"
# machinery: 3 calls
{
  usage_line req_M1 2026-07-11T10:00:00.000Z claude-haiku-4-5 100 0 10 2 text
  usage_line req_M2 2026-07-11T10:00:01.000Z claude-haiku-4-5 100 0 10 2 text
  usage_line req_M3 2026-07-11T10:00:02.000Z claude-haiku-4-5 100 0 10 2 text
} | mkagent "$R4" wf_class-004 dddd0000
# item worker: 8 calls (above SPEND_MACHINERY_MAX_CALLS=6, below the profile floor)
{
  i=1
  while [ "$i" -le 8 ]; do
    usage_line "req_W$i" "2026-07-11T11:00:0${i}.000Z" claude-opus-5 500 100 20 4 text
    i=$((i + 1))
  done
} | mkagent "$R4" wf_class-004 eeee0000
J4="$(run "$R4")"
check_eq "CLASSIFY: the 3-call agent is machinery" "1" "$(printf '%s' "$J4" | jq -r '.machinery.agents')"
check_eq "CLASSIFY: the 8-call agent is an item worker" "1" "$(printf '%s' "$J4" | jq -r '.item_workers.agents')"
check_eq "CLASSIFY: machinery units (3 * (100*0.1+0+10*5+2) = 3*62)" \
  "186" "$(printf '%s' "$J4" | jq -r '.machinery.units')"
check_eq "CLASSIFY: item-worker units (8 * (500*0.1+100*1.25+20*5+4) = 8*279)" \
  "2232" "$(printf '%s' "$J4" | jq -r '.item_workers.units')"
check_eq "CLASSIFY: percentages sum to 100" "100" \
  "$(printf '%s' "$J4" | jq -r '(.machinery.pct + .item_workers.pct)')"
check_eq "CLASSIFY: neither agent reaches the PROFILE floor, so the profile is empty" \
  "0" "$(printf '%s' "$J4" | jq -r '.worker_profile.n')"
check_eq "CLASSIFY: the threshold that produced the split is echoed back" \
  "6" "$(printf '%s' "$J4" | jq -r '.thresholds.machinery_max_calls')"

# 4b. The profile floor is a SECOND, independent threshold: lowering it to 8
#     admits the 8-call worker without changing the attribution split.
J4B="$(SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
       SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=8 \
       bash "$BIN" --root "$R4" --format json)"
check_eq "PROFILE: lowering the profile floor admits the 8-call worker" \
  "1" "$(printf '%s' "$J4B" | jq -r '.worker_profile.n')"
check_eq "PROFILE: median API calls of a one-agent population is that agent's count" \
  "8" "$(printf '%s' "$J4B" | jq -r '.worker_profile.median_api_calls')"
check_eq "PROFILE: the attribution split is UNCHANGED by the profile floor" \
  "$(printf '%s' "$J4" | jq -r '.machinery.units')" "$(printf '%s' "$J4B" | jq -r '.machinery.units')"

# 4c. Median of an EVEN-sized population averages the middle two — and the
#     sort is numeric, not lexicographic (the classic `sort` trap: 9 > 100).
R4C="$TMP/median"
for n in 9 101; do
  {
    i=1
    while [ "$i" -le "$n" ]; do
      usage_line "req_$n-$i" "2026-07-12T10:00:00.000Z" claude-opus-5 10 0 0 0 text
      i=$((i + 1))
    done
  } | mkagent "$R4C" wf_median-005 "agent$n"
done
J4C="$(SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
       SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=9 \
       bash "$BIN" --root "$R4C" --format json)"
check_eq "PROFILE: even-sized median averages the middle two ((9+101)/2 = 55, NUMERICALLY sorted — a lexicographic sort would put 101 first and answer 55 by luck on the calls column but wrongly elsewhere)" \
  "55" "$(printf '%s' "$J4C" | jq -r '.worker_profile.median_api_calls')"

# ===========================================================================
# 5. Window and run filters.
# ===========================================================================
R5="$TMP/filters"
usage_line req_OLD 2026-07-01T10:00:00.000Z claude-opus-5 100 0 0 0 text | mkagent "$R5" wf_old-006 f0000000
usage_line req_NEW 2026-07-31T10:00:00.000Z claude-opus-5 200 0 0 0 text | mkagent "$R5" wf_new-007 f1000000
check_eq "FILTER: --since keeps only the later agent" \
  "20" "$(run "$R5" --since 2026-07-15 | jq -r '.units_total')"
check_eq "FILTER: --until keeps only the earlier agent" \
  "10" "$(run "$R5" --until 2026-07-15 | jq -r '.units_total')"
check_eq "FILTER: no window keeps both" "30" "$(run "$R5" | jq -r '.units_total')"
check_eq "FILTER: --run selects one workflow run" \
  "20" "$(run "$R5" --run wf_new-007 | jq -r '.units_total')"
check_eq "FILTER: --run accepts the bare id without the wf_ prefix" \
  "20" "$(run "$R5" --run new-007 | jq -r '.units_total')"
check_eq "FILTER: --run accepts a comma-separated list" \
  "30" "$(run "$R5" --run wf_old-006,wf_new-007 | jq -r '.units_total')"
check_eq "FILTER: an unmatched --run yields an empty, valid report" \
  "0" "$(run "$R5" --run wf_nope | jq -r '.units_total')"
check_eq "FILTER: the applied filters are echoed back" \
  "2026-07-15" "$(run "$R5" --since 2026-07-15 | jq -r '.filters.since')"

# 5b. An agent must never be split across a window boundary: its date is the
#     date of its FIRST API call, even when later calls fall the next day.
R5B="$TMP/midnight"
{
  usage_line req_N1 2026-07-20T23:59:00.000Z claude-opus-5 100 0 0 0 text
  usage_line req_N2 2026-07-21T00:01:00.000Z claude-opus-5 100 0 0 0 text
} | mkagent "$R5B" wf_midnight-008 f2000000
check_eq "FILTER: a midnight-spanning agent is attributed WHOLE to its first-call date" \
  "20" "$(run "$R5B" --until 2026-07-20 | jq -r '.units_total')"
check_eq "FILTER: ...and is wholly EXCLUDED by a window that starts after it" \
  "0" "$(run "$R5B" --since 2026-07-21 | jq -r '.units_total')"

# ===========================================================================
# 6. Model attribution.
# ===========================================================================
R6="$TMP/models"
{
  usage_line req_H1 2026-07-13T10:00:00.000Z claude-haiku-4-5 100 0 0 0 text
  usage_line req_O1 2026-07-13T10:00:01.000Z claude-opus-5     200 0 0 0 text
} | mkagent "$R6" wf_models-009 f3000000
J6="$(run "$R6")"
check_eq "BY_MODEL: haiku attribution" "10" "$(printf '%s' "$J6" | jq -r '.by_model["claude-haiku-4-5"]')"
check_eq "BY_MODEL: opus attribution"  "20" "$(printf '%s' "$J6" | jq -r '.by_model["claude-opus-5"]')"
check_eq "BY_MODEL: the parts sum to units_total (internally consistent)" \
  "$(printf '%s' "$J6" | jq -r '.units_total')" \
  "$(printf '%s' "$J6" | jq -r '[.by_model[]] | add')"

# ===========================================================================
# 7. Degradation and hygiene.
# ===========================================================================
check "EMPTY: a nonexistent root exits 0 with a legible text report" \
  bash -c "bash '$BIN' --root '$TMP/does-not-exist' | grep -q 'no transcripts matched'"
check "EMPTY: a nonexistent root still emits VALID JSON" \
  bash -c "bash '$BIN' --root '$TMP/does-not-exist' --format json | jq -e . >/dev/null"
check_eq "EMPTY: units_total is 0, never null" \
  "0" "$(bash "$BIN" --root "$TMP/does-not-exist" --format json | jq -r '.units_total')"

R7="$TMP/torn"
{
  usage_line req_T1 2026-07-14T10:00:00.000Z claude-opus-5 100 0 0 0 text
  printf '{"partial": "line with no closing brace"\n'
  printf 'not json at all\n'
} | mkagent "$R7" wf_torn-010 f4000000
check_eq "TORN: an unparseable line is skipped, the surrounding data survives" \
  "10" "$(run "$R7" | jq -r '.units_total')"

check "USAGE: --help exits 0 and prints a usage block" \
  bash -c "bash '$BIN' --help | grep -q 'usage: pipeline-spend-report.sh'"
check "USAGE: an unknown flag exits 2" \
  bash -c "bash '$BIN' --bogus; test \$? -eq 2"
check "USAGE: --format xml exits 2" \
  bash -c "bash '$BIN' --format xml; test \$? -eq 2"
check "USAGE: a malformed --since exits non-zero with a named error" \
  bash -c "bash '$BIN' --since 7/1/2026 2>&1 | grep -q 'must be YYYY-MM-DD'"
check "TEXT: the default format is human-readable, not JSON" \
  bash -c "bash '$BIN' --root '$R1' | grep -q 'cost-weighted spend'"
check "TEXT: the report names the settings its weights came from" \
  bash -c "bash '$BIN' --root '$R1' | grep -q 'SPEND_WEIGHT_'"

# ===========================================================================
# 8. STATIC PROOFS of the two "never do this" traps.
# ===========================================================================
# Trap 3 — the transcript records one tool_use per assistant message and so
# CANNOT express parallelism. A metric derived from it would be structurally
# incapable of being right, and was falsified against a control during #953.
check "STATIC: no tool-call-parallelism metric is derived (trap 3)" \
  bash -c "! grep -nE 'parallel(ism)?[^-]' '$BIN' | grep -vE '^[0-9]+:[[:space:]]*#'"
check "STATIC: the tool never even reads .message.content (so it cannot count tool_use blocks)" \
  bash -c "! grep -n 'message\\.content' '$BIN' | grep -vE '^[0-9]+:[[:space:]]*#'"

# Trap 4 — BSD/macOS dialect. Each of these failed live during #953.
check "STATIC: no awk asort() (absent from BSD awk)" \
  bash -c "! grep -n 'asort' '$BIN' | grep -vE '^[0-9]+:[[:space:]]*#'"
check "STATIC: no GNU-only \`date -d\`" bash -c "! grep -qE \"date [^|]*-d \" '$BIN'"
check "STATIC: no GNU sed label/branch loop" bash -c "! grep -qE 'sed .*:[a-z]+;' '$BIN'"

# ===========================================================================
# 9. The kernel-side `tokens` report.d producer implementation
#    (workflows/scripts/report-producers/tokens -- relocated out of
#    .temperloop/report.d/tokens by temperloop#980; that path is now a
#    locator + exec shim only, see bin/subcommands/tests/test_tokens_producer.sh
#    for ITS coverage).
# ===========================================================================
if [ -x "$PRODUCER" ]; then
  OUT9="$(SPEND_TRANSCRIPT_ROOT="$R1" "$PRODUCER")"
  check "PRODUCER: stdout parses as a single JSON object" \
    bash -c "printf '%s' '$OUT9' | jq -e 'type == \"object\"' >/dev/null"
  check "PRODUCER: carries a NUMERIC tokens_spent (report.contract.md's stricter rule)" \
    bash -c "printf '%s' '$OUT9' | jq -e '(.tokens_spent | type) == \"number\"' >/dev/null"
  check "PRODUCER: by_model, when present, is an object" \
    bash -c "printf '%s' '$OUT9' | jq -e '(has(\"by_model\") | not) or ((.by_model | type) == \"object\")' >/dev/null"
  check "PRODUCER: exits 0" bash -c "SPEND_TRANSCRIPT_ROOT='$R1' '$PRODUCER' >/dev/null"

  # Degradation: relocate a lone copy (no sibling pipeline-spend-report.sh)
  # so its dirname-relative sibling lookup finds no profiler.
  mkdir -p "$TMP/orphan"
  cp "$PRODUCER" "$TMP/orphan/tokens"
  chmod +x "$TMP/orphan/tokens"
  OUT9B="$("$TMP/orphan/tokens"; echo "rc=$?")"
  check "PRODUCER: with no profiler reachable, prints the contract's skip line" \
    bash -c "printf '%s' '$OUT9B' | grep -q 'skipped -- tokens: producer unavailable'"
  check "PRODUCER: ...and still exits 0 (a skip is never an error)" \
    bash -c "printf '%s' '$OUT9B' | grep -q 'rc=0'"

  # Degradation: no jq on PATH.
  mkdir -p "$TMP/emptybin"
  OUT9C="$(PATH="$TMP/emptybin:/usr/bin:/bin" bash -c "command -v jq >/dev/null 2>&1 && echo HASJQ || '$PRODUCER'" 2>/dev/null)"
  case "$OUT9C" in
    HASJQ) : ;;  # this host has jq in /usr/bin; the branch is covered by the orphan case above
    *) check "PRODUCER: with no jq, prints the skip line" \
         bash -c "printf '%s' '$OUT9C' | grep -q 'skipped -- tokens: producer unavailable'" ;;
  esac

  # Egress: the producer must never open a network connection. This is the
  # same question `make test-producer-egress` asks repo-wide; asserted here
  # too so the producer's own suite fails on a regression even if the
  # Makefile wiring is ever dropped.
  check "PRODUCER: no network-call idiom in the producer body" \
    bash -c "! grep -nE '(^|[^A-Za-z0-9_])(curl|wget|nc|netcat|ssh|scp|rsync|telnet|ftp)([ \\t]|\$)|/dev/(tcp|udp)/' '$PRODUCER' | grep -vE '^[0-9]+:[[:space:]]*#'"
  check "PRODUCER: never calls gh either (this producer reads local files only)" \
    bash -c "! grep -nE '(^|[^A-Za-z0-9_])gh ' '$PRODUCER' | grep -vE '^[0-9]+:[[:space:]]*#'"
else
  printf '  - skipped: workflows/scripts/report-producers/tokens not present or not executable\n'
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d pipeline-spend-report checks passed\n' "$pass"
