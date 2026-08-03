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

  # Degradation: an unrecognized record shape from the profiler (units_total
  # present but not a number) -- the producer's own `select((.units_total |
  # type) == "number")` filter drops it, so $out is empty and it skips.
  FAKEROOT="$TMP/fake-profiler-kernel/workflows/scripts"
  mkdir -p "$FAKEROOT/report-producers"
  cp "$PRODUCER" "$FAKEROOT/report-producers/tokens"
  chmod +x "$FAKEROOT/report-producers/tokens"
  cat > "$FAKEROOT/pipeline-spend-report.sh" <<'EOF'
#!/usr/bin/env bash
# fixture: emits a record whose units_total is NOT a number (bad shape)
echo '{"units_total":"not-a-number","by_model":{}}'
EOF
  chmod +x "$FAKEROOT/pipeline-spend-report.sh"
  OUT9D="$("$FAKEROOT/report-producers/tokens"; echo "rc=$?")"
  check "PRODUCER: an unrecognized record shape (non-numeric units_total) prints the skip line" \
    bash -c "printf '%s' '$OUT9D' | grep -q 'skipped -- tokens: producer unavailable'"
  check "PRODUCER: ...and still exits 0" \
    bash -c "printf '%s' '$OUT9D' | grep -q 'rc=0'"

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

  # =========================================================================
  # 9e-9k. CORPUS SCOPING (temperloop#983) — "fix what corpus the token
  # number is drawn from, and say so in the report". Hardened per TWO shell
  # review rounds: round 1 found two BLOCKING issues in the first cut (a
  # silent zero under a "THIS git checkout" notice when the derived root
  # doesn't exist; report.sh never actually cd'ing to the target repo) plus
  # several secondary findings; round 2 found the LC_ALL=C locale pin
  # measurably moved AWAY from correctness (removed, see the producer's own
  # header) and a missing 200-character encoded-name cap (9k below), plus
  # the drift-guard and 9i-discrimination fixes above and below (see git log
  # for both review rounds this addresses).
  #
  #   9e: the producer, run from a real (fixture) git checkout with a
  #       POPULATED project directory, scopes --root to THAT checkout's own
  #       Claude Code project directory and excludes a DECOY corpus placed
  #       under a different project directory on the same fake $HOME -- the
  #       important half, per this item's own acceptance bullet: a test that
  #       only checked the notice string renders would pass even if the
  #       number were still machine-wide.
  #   9f: an explicit SPEND_TRANSCRIPT_ROOT override to a value OTHER than
  #       its own default still wins over repo-scoping.
  #   9g: end-to-end through `bin/subcommands/report.sh` (i.e. `temperloop
  #       report` itself) -- the comparability caveat actually renders inline
  #       with the tokens headline, not just in the producer's own stdout.
  #   9h: the two previously-untested degrade arms -- a non-git cwd, and an
  #       unset $HOME -- both fall back to the GENERIC machine-wide notice,
  #       never a false "THIS git checkout" claim.
  #   9i: BLOCKING finding 1 -- a derived root that does not exist (a fresh
  #       checkout, a linked worktree, a CI runner) must render the
  #       path-naming notice, never a silent "0 tokens" under a
  #       THIS-checkout claim; discriminated with a decoy corpus so a
  #       nonzero total proves the fallback actually ran, not just that a
  #       path was empty.
  #   9j: ALSO-FIX finding 3 -- $SPEND_TRANSCRIPT_ROOT exported at its OWN
  #       documented default (exactly what every session that sources
  #       build.config.sh at its own Step 0 inherits) must NOT be treated as
  #       an override; repo-scoping must still engage.
  #   9k: review round 2, finding 2 (+ temperloop#995) -- an encoded name
  #       over Claude Code's 200-character cap whose truncated prefix
  #       matches NO project directory must render its OWN distinct notice
  #       (naming the prefix GLOB it searched, never the untruncated path,
  #       which structurally cannot exist), not the path-naming notice from
  #       9i; same decoy-discrimination shape as 9i.
  #   9l: temperloop#995 -- the RESOLUTION half: an over-cap encoded name
  #       whose truncated prefix matches EXACTLY ONE project directory is
  #       repo-scoped to that directory (the decoy on the same fake $HOME
  #       is excluded), under a notice that says the directory was resolved
  #       by prefix match rather than by full name.
  #   9m: temperloop#995 -- an over-cap prefix matching MORE THAN ONE
  #       project directory is ambiguous: it must degrade to machine-wide
  #       naming the match count, never silently pick one of them.
  #
  # Every negative assertion below ("does not claim X") is paired with a
  # positive assertion on what the notice DOES say, in the SAME jq
  # expression where practical -- a bare `! ... | grep -q X` passes
  # vacuously on empty output or a jq error, which is exactly the failure
  # mode for the two assertions guarding the notice from lying (review
  # finding 7).
  # =========================================================================

  # ---------------------------------------------------------------------
  # DRIFT GUARD (temperloop#983 review round 2, finding 3): the producer
  # hardcodes its own copy of build.config.sh's SPEND_TRANSCRIPT_ROOT
  # default (`default_transcript_root="${HOME:-}/.claude/projects"`,
  # workflows/scripts/report-producers/tokens) so it can tell an EXPLICIT
  # caller override apart from the value every /build session inherits
  # merely by sourcing build.config.sh (ALSO-FIX finding 3, already fixed).
  # There is no live link between the two literals -- if build.config.sh's
  # own default ever changes, the producer's comparison silently INVERTS:
  # every /build session's exported (new) default now reads as a
  # "different" value, gets classified as an override, and repo-scoping is
  # silently disabled again -- re-arming the exact bug ALSO-FIX 3 closed,
  # from a one-line edit in a completely different file that would have no
  # reason to touch this test. Caught here by EXPANDING both literals under
  # a synthetic $HOME and asserting the results agree -- semantic agreement,
  # not a brittle string diff (the two sides use different shell syntax,
  # `$HOME/...` vs `${HOME:-}/...`, which are equivalent once expanded).
  # ---------------------------------------------------------------------
  expand_under_home() { # expand_under_home <raw-shell-expr> <home-value>
    HOME="$2" bash -c "printf '%s' \"$1\""
  }
  BUILD_CONFIG_SH="$REPO_ROOT/workflows/scripts/build/build.config.sh"
  build_default_raw="$(grep -oE 'SPEND_TRANSCRIPT_ROOT:=[^}]+' "$BUILD_CONFIG_SH" | head -1 | sed 's/^SPEND_TRANSCRIPT_ROOT:=//')"
  producer_default_raw="$(grep -oE 'default_transcript_root="[^"]+"' "$PRODUCER" | head -1 | sed 's/^default_transcript_root="//; s/"$//')"
  check "DRIFT SETUP: both the build.config.sh default and the producer's own copy of it were found (a miss here means one side's literal shape changed and this drift guard itself needs updating, not a pass)" \
    bash -c "[ -n '$build_default_raw' ] && [ -n '$producer_default_raw' ]"
  SYNTHETIC_HOME_FOR_DRIFT="/synthetic-home-983-drift-check"
  build_default_expanded="$(expand_under_home "$build_default_raw" "$SYNTHETIC_HOME_FOR_DRIFT")"
  producer_default_expanded="$(expand_under_home "$producer_default_raw" "$SYNTHETIC_HOME_FOR_DRIFT")"
  check_eq "DRIFT: build.config.sh's SPEND_TRANSCRIPT_ROOT default and the producer's own default_transcript_root literal expand to the SAME value under a synthetic \$HOME -- a mismatch here means the two literals have drifted apart and repo-scoping's override-detection is silently disabled again" \
    "$build_default_expanded" "$producer_default_expanded"

  FAKE_HOME="$TMP/fake-home-983"
  FAKEREPO="$TMP/fake-repo-983"
  mkdir -p "$FAKEREPO"
  git -C "$FAKEREPO" init -q
  REAL_FAKEREPO_ROOT="$(git -C "$FAKEREPO" rev-parse --show-toplevel 2>/dev/null)"

  # Review finding 9: a git-init/rev-parse failure here used to be silently
  # swallowed (`|| true`), so the ENTIRE 9e-9j block -- everything that
  # proves this item's core fix -- could vanish from the suite without ever
  # failing it. Make that LOUD: route it through `check` (counts toward
  # $fail) instead of a bare informational skip line.
  check "SCOPE SETUP: the fixture checkout initializes and resolves its own git toplevel (required for 9e-9j; a failure here is a broken test environment, not a legitimate skip)" \
    test -n "$REAL_FAKEREPO_ROOT"

  if [ -n "$REAL_FAKEREPO_ROOT" ]; then
    ENC="$(printf '%s' "$REAL_FAKEREPO_ROOT" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
    INSCOPE_ROOT="$FAKE_HOME/.claude/projects/$ENC"
    DECOY_ROOT="$FAKE_HOME/.claude/projects/-some-other-unrelated-repo"

    # in-scope: 1 call. units = 1000*0.1 + 200*1.25 + 40*5 + 8*1 = 558
    { usage_line reqS1 2026-07-10T10:00:00.000Z claude-opus-5 1000 200 40 8 text; } \
      | mkagent "$INSCOPE_ROOT" wf_scope-001 s0001
    # decoy: a DIFFERENT project's spend on the same machine -- must NOT be
    # counted. units = 9000*0.1 + 9000*1.25 + 900*5 + 90*1 = 16740. If it
    # leaked in, the total would be 558+16740=17298, not 558.
    { usage_line reqD1 2026-07-10T10:00:00.000Z claude-opus-5 9000 9000 900 90 text; } \
      | mkagent "$DECOY_ROOT" wf_decoy-001 d0001

    RUN_PRODUCER_SCOPED() { # extra args forwarded to env
      (cd "$FAKEREPO" && env -u SPEND_TRANSCRIPT_ROOT HOME="$FAKE_HOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 \
        SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 \
        BASELINE_SNAPSHOT_LOOKBACK_DAYS=36500 "$@")
    }

    OUT9E="$(RUN_PRODUCER_SCOPED "$PRODUCER")"
    check_eq "SCOPE 9e: repo-scoped tokens_spent counts ONLY this checkout's own transcripts (558) -- the decoy project's spend on the same machine is excluded" \
      "558" "$(printf '%s' "$OUT9E" | jq -r '.tokens_spent')"
    check "SCOPE 9e: ...i.e. the total is NOT the sum of both corpora (would be 17298 if the decoy leaked in)" \
      bash -c "printf '%s' '$OUT9E' | jq -e '.tokens_spent != 17298' >/dev/null"
    check "SCOPE 9e: the notice states THIS-checkout-only scoping AND does not also claim machine-wide (one combined check: both halves must hold on the SAME parse, so a jq error or empty notice fails this too, not just the grep half)" \
      bash -c "printf '%s' '$OUT9E' | jq -e '(.notice | type) == \"string\" and (.notice | test(\"THIS git checkout\")) and ((.notice | test(\"every Claude Code project\")) | not)' >/dev/null"

    # --- 9f: an explicit SPEND_TRANSCRIPT_ROOT override to a DIFFERENT root
    # (not its own default -- see 9j below for the defaulted case) still
    # wins over repo-scoping.
    OUT9F="$(cd "$FAKEREPO" && SPEND_TRANSCRIPT_ROOT="$R1" "$PRODUCER")"
    check "SCOPE 9f: an explicit, non-default SPEND_TRANSCRIPT_ROOT override still produces a usable object, and its notice is the GENERIC machine-wide caveat, NOT a false this-checkout claim (one combined check)" \
      bash -c "printf '%s' '$OUT9F' | jq -e '((.tokens_spent | type) == \"number\") and (.notice | type) == \"string\" and (.notice | test(\"every Claude Code project\")) and ((.notice | test(\"THIS git checkout\")) | not)' >/dev/null"

    # --- 9g: end-to-end through report.sh (`temperloop report`) -- the
    # notice must actually RENDER inline with the tokens headline, using the
    # REAL kernel-side producer (not a stub), so this proves the shipped
    # wiring, not just the producer's own stdout.
    REPORT_SH="$REPO_ROOT/bin/subcommands/report.sh"
    check "SCOPE SETUP: bin/subcommands/report.sh exists and is executable (required for 9g's end-to-end render; a failure here is a broken checkout, not a legitimate skip)" \
      test -x "$REPORT_SH"
    if [ -x "$REPORT_SH" ]; then
      mkdir -p "$FAKEREPO/.temperloop/report.d"
      printf '%s\n' '{"generated_at":"2026-07-10T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"x/y"},"metrics":{"available":true,"pr_throughput":{"merged_count":1},"time_to_merge_hours":{"median":1},"review_latency_hours":{"median":1},"issue_backlog":{"median_age_days":1}}}' \
        > "$FAKEREPO/.temperloop/baseline.jsonl"
      cat > "$FAKEREPO/.temperloop/report.d/tokens" <<EOF
#!/usr/bin/env bash
exec "$PRODUCER"
EOF
      chmod +x "$FAKEREPO/.temperloop/report.d/tokens"

      # Written to a file rather than captured into a shell var + re-embedded
      # in a quoted bash -c string: report.sh's own kernel-tier prose
      # legitimately contains single quotes (e.g. "'temperloop
      # baseline-snapshot'"), which would break the single-quote-embedding
      # trick this file's other checks rely on. grep the file directly.
      E2E_FILE="$TMP/e2e-983-report-out.txt"
      RUN_PRODUCER_SCOPED bash "$REPORT_SH" >"$E2E_FILE" 2>&1
      check "SCOPE 9g E2E: temperloop report renders the tokens headline" \
        grep -q "Tokens spent vs items merged" "$E2E_FILE"
      check "SCOPE 9g E2E: temperloop report renders the repo-scoping comparability notice inline with the headline" \
        grep -q "notice: directional cost-weighted token spend, scoped to THIS git checkout" "$E2E_FILE"
      check "SCOPE 9g E2E: the rendered ratio uses the REPO-SCOPED total (558), not the combined-with-decoy total" \
        grep -q "558 tokens / 1 merged" "$E2E_FILE"
    fi

    # =======================================================================
    # 9h: previously-untested degrade arms (review finding 8) -- a non-git
    # cwd, and an unset $HOME. Both must exit 0, use the GENERIC
    # machine-wide notice, and must NOT claim "THIS git checkout".
    # =======================================================================
    NONGIT="$TMP/nongit-983"
    mkdir -p "$NONGIT"
    NOSUCHHOME="$TMP/no-such-home-983"
    OUT9H1="$(cd "$NONGIT" && env -u SPEND_TRANSCRIPT_ROOT HOME="$NOSUCHHOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 "$PRODUCER")"
    rc9h1=$?
    check "SCOPE 9h: a non-git cwd still exits 0" test "$rc9h1" -eq 0
    check "SCOPE 9h: ...its notice is the GENERIC machine-wide caveat, and does NOT claim THIS-checkout scoping it never did (one combined check)" \
      bash -c "printf '%s' '$OUT9H1' | jq -e '(.notice | type) == \"string\" and (.notice | test(\"every Claude Code project\")) and ((.notice | test(\"THIS git checkout\")) | not)' >/dev/null"

    # A genuinely unset $HOME (not merely nonexistent, as in 9h1 above) is a
    # DIFFERENT degrade path from the notice-bearing ones: this producer's
    # own `[ -n "${HOME:-}" ]` guard correctly skips repo-scoping, but the
    # FALLBACK machine-wide profiler invocation then ALSO needs $HOME to
    # resolve build.config.sh's own `${SPEND_TRANSCRIPT_ROOT:=$HOME/...}`
    # default -- under that script's `set -u`, a truly-unset $HOME is a
    # hard "unbound variable" error, not a soft default. So the profiler
    # itself fails, and this producer's PRE-EXISTING top-level `|| skip`
    # catches it exactly like any other profiler failure: the contract's
    # skip line, exit 0 -- never a crash, never partial JSON. Empirically
    # confirmed while writing this test (not assumed): asserted directly
    # here rather than expecting a notice-bearing object that this arm does
    # not actually produce.
    OUT9H2="$(cd "$FAKEREPO" && env -u SPEND_TRANSCRIPT_ROOT -u HOME \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 "$PRODUCER")"
    rc9h2=$?
    check "SCOPE 9h: an unset \$HOME (inside an otherwise-real git checkout) still exits 0" test "$rc9h2" -eq 0
    check_eq "SCOPE 9h: ...and degrades to the contract's own skip line (the profiler itself cannot resolve build.config.sh's HOME-keyed default with no \$HOME at all) -- never a crash, never a false THIS-checkout claim" \
      "skipped -- tokens: producer unavailable" "$OUT9H2"

    # =======================================================================
    # 9i: BLOCKING finding 1 -- a derived repo-scoped root that does NOT
    # exist (a fresh checkout, a linked worktree that has never itself run a
    # workflow, a CI runner, any $HOME differing from the session that
    # recorded the transcripts) must render the path-naming notice -- never
    # a silent "0 tokens" dressed up as "THIS git checkout".
    #
    # Review round 2, "also (small)" finding: an EMPTY fake $HOME makes both
    # the pre-fix bug (0 under a false THIS-checkout claim) and the fixed
    # behavior (0 under the honest fallback notice) report the SAME number
    # -- so a bare `tokens_spent == 0` check passes identically whether or
    # not the fix actually engaged; only the notice text discriminates. Give
    # this fake $HOME a DECOY project dir under a DIFFERENT (non-$ENC) name
    # holding a KNOWN non-zero corpus, so a passing tokens_spent assertion
    # PROVES the fallback branch actually walked the machine-wide corpus,
    # not just that some path happened to be empty.
    # =======================================================================
    EMPTY_FAKE_HOME="$TMP/fake-home-983-empty"
    mkdir -p "$EMPTY_FAKE_HOME"
    DECOY9I_ROOT="$EMPTY_FAKE_HOME/.claude/projects/-some-other-unrelated-repo-9i"
    # units = 3000*0.1 + 800*1.25 + 150*5 + 30*1 = 300 + 1000 + 750 + 30 = 2080
    { usage_line reqD9I 2026-07-10T10:00:00.000Z claude-opus-5 3000 800 150 30 text; } \
      | mkagent "$DECOY9I_ROOT" wf_decoy9i-001 d9i0001
    EXPECTED_MISSING_PATH="$EMPTY_FAKE_HOME/.claude/projects/$ENC"
    OUT9I="$(cd "$FAKEREPO" && env -u SPEND_TRANSCRIPT_ROOT HOME="$EMPTY_FAKE_HOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 "$PRODUCER")"
    rc9i=$?
    check "SCOPE 9i: a nonexistent repo-scoped root still exits 0 (a genuinely-empty checkout is real, not an error)" \
      test "$rc9i" -eq 0
    check_eq "SCOPE 9i: ...and tokens_spent is the DECOY's 2080 -- proving the fallback branch actually walked the machine-wide corpus under this fake \$HOME, not just that the repo-scoped path was empty (0 would pass identically under the pre-fix bug)" \
      "2080" "$(printf '%s' "$OUT9I" | jq -r '.tokens_spent')"
    check "SCOPE 9i: ...and the notice names the EXACT repo-scoped path it looked for (so the operator can diff it against their own 'ls ~/.claude/projects'), and is neither of the other notice variants (one combined check)" \
      bash -c "printf '%s' '$OUT9I' | jq -e --arg p \"$EXPECTED_MISSING_PATH\" '(.notice | type) == \"string\" and (.notice | contains(\$p)) and (.notice | test(\"no Claude Code transcripts recorded\")) and ((.notice | test(\"THIS git checkout\")) | not) and ((.notice | test(\"every Claude Code project\")) | not) and ((.notice | test(\"200-character\")) | not)' >/dev/null"

    # =======================================================================
    # 9j: ALSO-FIX finding 3 -- $SPEND_TRANSCRIPT_ROOT exported at its OWN
    # documented default ($HOME/.claude/projects, exactly what every session
    # that sources build.config.sh at its own Step 0 inherits per the
    # kernel's § Named-setting convention) must NOT be treated as a caller
    # override. Without this, the fix silently no-ops under /build itself.
    # Reuses 9e's populated FAKE_HOME/INSCOPE_ROOT so a correct pass proves
    # repo-scoping actually re-engaged (558), not just that SOME number came
    # back.
    # =======================================================================
    OUT9J="$(cd "$FAKEREPO" && env HOME="$FAKE_HOME" SPEND_TRANSCRIPT_ROOT="$FAKE_HOME/.claude/projects" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 BASELINE_SNAPSHOT_LOOKBACK_DAYS=36500 "$PRODUCER")"
    check_eq "SCOPE 9j: SPEND_TRANSCRIPT_ROOT exported at exactly its own default value does NOT block repo-scoping -- still 558, not the combined-with-decoy 17298 a defeated fix would report" \
      "558" "$(printf '%s' "$OUT9J" | jq -r '.tokens_spent')"
    check "SCOPE 9j: ...and the notice confirms repo-scoping actually re-engaged (THIS git checkout), not the machine-wide fallback" \
      bash -c "printf '%s' '$OUT9J' | jq -e '(.notice | type) == \"string\" and (.notice | test(\"THIS git checkout\"))' >/dev/null"

    # =======================================================================
    # 9k: review round 2, finding 2 -- Claude Code caps an encoded project
    # name at 200 characters (truncate + unreproducible hash beyond that).
    # Since temperloop#995 the producer RESOLVES that case by matching the
    # truncated prefix (9l below); this arm is the NO-MATCH one -- nothing
    # under the fake $HOME starts with that prefix, so it must degrade to
    # machine-wide under a notice that names the GLOB it searched, and must
    # still never claim the untruncated path exists (it structurally cannot
    # under Claude Code's own naming rule). A fixture checkout whose
    # absolute path encodes to well over 200 characters (built with dynamic
    # padding so it clears the bar regardless of how long this machine's own
    # tmp root happens to be), pointed at a fake $HOME holding ONLY a decoy
    # corpus under a DIFFERENT name -- same discriminating shape as 9i: a
    # passing tokens_spent proves the cap branch actually fell through to
    # the machine-wide fallback, not that it coincidentally returned 0.
    # =======================================================================
    PAD_LEN=220
    LONGPAD="$(printf 'a%.0s' $(seq 1 "$PAD_LEN"))"
    LONGREPO="$TMP/longpath-983/$LONGPAD"
    mkdir -p "$LONGREPO"
    git -C "$LONGREPO" init -q
    REAL_LONGREPO_ROOT="$(git -C "$LONGREPO" rev-parse --show-toplevel 2>/dev/null)"
    ENC_LONG="$(printf '%s' "$REAL_LONGREPO_ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
    enc_long_len=${#ENC_LONG}
    check "SCOPE 9k SETUP: the fixture checkout's encoded name actually exceeds 200 characters (required to exercise the cap; a failure here means PAD_LEN needs to grow on this machine, not a legitimate skip)" \
      test "$enc_long_len" -gt 200

    LONGCAP_HOME="$TMP/fake-home-983-longcap"
    mkdir -p "$LONGCAP_HOME"
    LONGCAP_DECOY_ROOT="$LONGCAP_HOME/.claude/projects/-decoy-longcap-9k"
    # units = 1000*0.1 + 500*1.25 + 60*5 + 12*1 = 100 + 625 + 300 + 12 = 1037
    { usage_line reqLC9K 2026-07-10T10:00:00.000Z claude-opus-5 1000 500 60 12 text; } \
      | mkagent "$LONGCAP_DECOY_ROOT" wf_longcap-001 lc9k0001

    OUT9K="$(cd "$LONGREPO" && env -u SPEND_TRANSCRIPT_ROOT HOME="$LONGCAP_HOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 "$PRODUCER")"
    rc9k=$?
    check "SCOPE 9k: a checkout path whose encoded name exceeds the 200-char cap still exits 0" \
      test "$rc9k" -eq 0
    check_eq "SCOPE 9k: ...and tokens_spent reflects the machine-wide DECOY corpus (1037) -- proving the cap check actually fell through to the fallback, not that it coincidentally returned 0" \
      "1037" "$(printf '%s' "$OUT9K" | jq -r '.tokens_spent')"
    check "SCOPE 9k: ...and the notice is the 200-CAP variant -- names the cap, NOT a specific path (the untruncated path cannot exist under Claude Code's own naming rule), and is none of the other three notice variants (one combined check)" \
      bash -c "printf '%s' '$OUT9K' | jq -e '(.notice | type) == \"string\" and (.notice | test(\"200-character\")) and (.notice | test(\"exceeds\")) and ((.notice | test(\"THIS git checkout\")) | not) and ((.notice | test(\"no Claude Code transcripts recorded\")) | not) and ((.notice | test(\"every Claude Code project\")) | not)' >/dev/null"
    # temperloop#995: the no-match arm must name the PREFIX GLOB it actually
    # searched -- a real, pasteable `ls` the operator can run against their
    # own ~/.claude/projects -- and say that nothing matched, so it reads
    # differently from the ambiguous arm (9m) on sight. `contains`, not
    # `test`: the glob's trailing `-*` is regex-significant to test().
    #
    # ASSERTED FROM A FILE, NOT THE `printf '%s' '$OUT'` EMBEDDING the older
    # checks above use: that idiom re-embeds captured stdout inside a
    # single-quoted `bash -c` string, so it only survives an output with an
    # EVEN number of apostrophes (the pairs cancel and the apostrophes are
    # merely deleted). These #995 notices carry an ODD count -- one "Claude
    # Code's" -- which flips the rest of the string OUT of quotes, exposing
    # it to word-splitting, `$` expansion, and glob expansion on the very
    # `-*` this assertion is about. Writing stdout to a file and passing the
    # jq program as ordinary argv to `check` removes the whole shell-quoting
    # layer instead of trying to escape through it.
    LONG_PREFIX="${ENC_LONG:0:200}"
    EXPECTED_CAP_GLOB="$LONGCAP_HOME/.claude/projects/$LONG_PREFIX-*"
    OUT9K_FILE="$TMP/out-9k.json"
    printf '%s' "$OUT9K" > "$OUT9K_FILE"
    check "SCOPE 9k: ...and that notice names the exact prefix GLOB it searched and says NOTHING matched it (temperloop#995 -- the operator can paste it straight into an ls)" \
      jq -e --arg g "$EXPECTED_CAP_GLOB" \
        '(.notice | contains($g)) and (.notice | test("no project directory matches"))' "$OUT9K_FILE"

    # =======================================================================
    # 9l: temperloop#995 -- the RESOLUTION half of the 200-char cap. Claude
    # Code stores an over-cap project under `<first-200-chars>-<hash>`, and
    # its OWN reverse lookup finds that directory by the 200-character
    # prefix rather than by recomputing the hash (which shell cannot). So a
    # fake $HOME carrying exactly ONE directory under that prefix must be
    # repo-scoped to it -- with a decoy corpus under a DIFFERENT name on the
    # same $HOME, so a passing number proves the prefix match actually
    # scoped (1116) rather than the fallback walking everything (17856).
    #
    # The `-<hash>` suffix here is deliberately arbitrary: the whole point
    # is that this producer never reproduces or parses it, only the prefix.
    # =======================================================================
    RESOLVE_HOME="$TMP/fake-home-995-resolve"
    RESOLVE_MATCH_ROOT="$RESOLVE_HOME/.claude/projects/$LONG_PREFIX-1a2b3c"
    RESOLVE_DECOY_ROOT="$RESOLVE_HOME/.claude/projects/-decoy-995-resolve"
    # in-scope: units = 2000*0.1 + 400*1.25 + 80*5 + 16*1 = 200+500+400+16 = 1116
    { usage_line reqR1 2026-07-10T10:00:00.000Z claude-opus-5 2000 400 80 16 text; } \
      | mkagent "$RESOLVE_MATCH_ROOT" wf_resolve-001 r9950001
    # decoy: units = 9000*0.1 + 9000*1.25 + 900*5 + 90*1 = 16740 (combined would be 17856)
    { usage_line reqR2 2026-07-10T10:00:00.000Z claude-opus-5 9000 9000 900 90 text; } \
      | mkagent "$RESOLVE_DECOY_ROOT" wf_resolvedecoy-001 r9950002

    OUT9L="$(cd "$LONGREPO" && env -u SPEND_TRANSCRIPT_ROOT HOME="$RESOLVE_HOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 \
        BASELINE_SNAPSHOT_LOOKBACK_DAYS=36500 "$PRODUCER")"
    rc9l=$?
    OUT9L_FILE="$TMP/out-9l.json"
    printf '%s' "$OUT9L" > "$OUT9L_FILE"
    check "SCOPE 9l: an over-cap checkout whose truncated prefix matches exactly one project directory still exits 0" \
      test "$rc9l" -eq 0
    check_eq "SCOPE 9l: ...and tokens_spent is the PREFIX-MATCHED directory's own 1116 -- not the machine-wide 17856 the pre-#995 cap degrade would have reported, and not 0" \
      "1116" "$(jq -r '.tokens_spent' "$OUT9L_FILE")"
    check "SCOPE 9l: ...and the notice claims THIS-checkout scoping (it genuinely is scoped) while stating the directory was resolved by the 200-char prefix match, and is none of the three fallback variants (one combined check)" \
      jq -e --arg g "$RESOLVE_HOME/.claude/projects/$LONG_PREFIX-*" \
        '(.notice | type) == "string" and (.notice | test("THIS git checkout")) and (.notice | test("200-character")) and (.notice | contains($g)) and ((.notice | test("no project directory matches")) | not) and ((.notice | test("no Claude Code transcripts recorded")) | not) and ((.notice | test("every Claude Code project")) | not)' "$OUT9L_FILE"

    # =======================================================================
    # 9m: temperloop#995 -- AMBIGUITY. Two checkouts identical across their
    # first 200 encoded characters both land under the same prefix, and the
    # hash suffix that would tell them apart is exactly what this producer
    # cannot reproduce. Picking one would be a silent wrong number, so the
    # ambiguous case must degrade to machine-wide and SAY it was ambiguous.
    # The two matching directories are left EMPTY and the corpus lives in a
    # decoy under a different name, so the expected total (2080) is
    # reachable ONLY through the machine-wide fallback.
    # =======================================================================
    AMBIG_HOME="$TMP/fake-home-995-ambig"
    mkdir -p "$AMBIG_HOME/.claude/projects/$LONG_PREFIX-1a2b3c" \
             "$AMBIG_HOME/.claude/projects/$LONG_PREFIX-9z8y7x"
    AMBIG_DECOY_ROOT="$AMBIG_HOME/.claude/projects/-decoy-995-ambig"
    # units = 3000*0.1 + 800*1.25 + 150*5 + 30*1 = 300 + 1000 + 750 + 30 = 2080
    { usage_line reqA1 2026-07-10T10:00:00.000Z claude-opus-5 3000 800 150 30 text; } \
      | mkagent "$AMBIG_DECOY_ROOT" wf_ambig-001 a9950001

    OUT9M="$(cd "$LONGREPO" && env -u SPEND_TRANSCRIPT_ROOT HOME="$AMBIG_HOME" \
        SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25 SPEND_WEIGHT_OUTPUT=5 \
        SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=1 \
        BASELINE_SNAPSHOT_LOOKBACK_DAYS=36500 "$PRODUCER")"
    rc9m=$?
    OUT9M_FILE="$TMP/out-9m.json"
    printf '%s' "$OUT9M" > "$OUT9M_FILE"
    check "SCOPE 9m: an ambiguous over-cap prefix (two matching project directories) still exits 0" \
      test "$rc9m" -eq 0
    check_eq "SCOPE 9m: ...and tokens_spent is the machine-wide DECOY corpus (2080) -- proving it declined BOTH candidates rather than silently scoping to whichever the glob listed first" \
      "2080" "$(jq -r '.tokens_spent' "$OUT9M_FILE")"
    check "SCOPE 9m: ...and the notice says the prefix was AMBIGUOUS, names how many directories matched (2) and the glob, and never claims THIS-checkout scoping (one combined check)" \
      jq -e --arg g "$AMBIG_HOME/.claude/projects/$LONG_PREFIX-*" \
        '(.notice | type) == "string" and (.notice | test("ambiguous")) and (.notice | test("2 project directories match")) and (.notice | contains($g)) and (.notice | test("200-character")) and ((.notice | test("THIS git checkout")) | not) and ((.notice | test("no Claude Code transcripts recorded")) | not) and ((.notice | test("every Claude Code project")) | not)' "$OUT9M_FILE"
  fi
else
  printf '  - skipped: workflows/scripts/report-producers/tokens not present or not executable\n'
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d pipeline-spend-report checks passed\n' "$pass"
