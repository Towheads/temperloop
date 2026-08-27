#!/usr/bin/env bash
#
# test_item_efficiency.sh — tests for workflows/scripts/emit-item-efficiency.sh
# and the per-class fields it consumes from workflows/scripts/pipeline-spend-report.sh
# (temperloop#943, "per-epic efficiency metric — tokens and wall-clock per
# merged item").
#
# THE CENTRAL TEST is #3: COMPOSITION, NOT REIMPLEMENTATION. Every token
# figure in an item-efficiency record must be byte-identical to the
# corresponding field of `pipeline-spend-report.sh --format json` over the
# same run filter — because that script, and only that script, encodes the
# four correctness traps #953 paid for (dedupe-by-requestId above all). A
# record whose numbers merely *look* right while being derived here would
# silently fork those traps the first time one of them is retuned. #3 asserts
# equality against the live profiler output, and #3b re-runs the profiler's own
# duplicated-usage fixture THROUGH the emit path so the dedupe is proven to
# survive composition rather than assumed to.
#
# Also asserted, because each is an explicit acceptance bar of the item:
#   - an un-supplied phase / un-measured wall-clock leg is `null`, NEVER 0
#     (an absent measurement and a zero measurement mean opposite things)
#   - the worker/mechanical agent counts come from the profiler's own class
#     split, so "agent counts by role" and "tokens by role" can never disagree
#   - degradation: no profiler, no jq-parsable report, no gh — warn + null,
#     exit 0, record still written (this hangs off a MERGE step)
#   - the canonical sink-spec header pointer and the README stream doc exist
#   - build.md still invokes the emit at 4d (the prose-rot guard the
#     validate-issue-touch-emit.sh family exists for, folded in here rather
#     than shipped as a fourth near-identical validator script)
#
# Synthetic transcript fixtures and a synthetic lake, both under a throwaway
# tmpdir. Zero network; never reads the operator's real ~/.claude corpus;
# never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-item-efficiency.sh"
SPEND="$REPO/workflows/scripts/pipeline-spend-report.sh"
README="$REPO/meta/data/raw/README.md"
BUILD_MD="$REPO/claude/commands/build.md"

[ -f "$EMIT" ] || { echo "FATAL: emit-item-efficiency.sh not found at $EMIT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/item-efficiency-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}

# usage_line <requestId|-> <ts> <model> <cache_read> <cache_create> <output> <input>
# Same shape as test_pipeline_spend_report.sh's fixture generator; `-` omits
# the requestId (the un-dedupable case).
usage_line() {
  local rid="$1" ts="$2" model="$3" cr="$4" cc="$5" out="$6" inp="$7"
  if [ "$rid" = "-" ]; then
    jq -cn --arg ts "$ts" --arg m "$model" \
      --argjson cr "$cr" --argjson cc "$cc" --argjson o "$out" --argjson i "$inp" \
      '{type:"assistant", timestamp:$ts, message:{role:"assistant", model:$m,
        usage:{cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$o, input_tokens:$i}}}'
  else
    jq -cn --arg r "$rid" --arg ts "$ts" --arg m "$model" \
      --argjson cr "$cr" --argjson cc "$cc" --argjson o "$out" --argjson i "$inp" \
      '{type:"assistant", requestId:$r, timestamp:$ts, message:{role:"assistant", model:$m,
        usage:{cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$o, input_tokens:$i}}}'
  fi
}
mkagent() { # mkagent <root> <wf_id> <agent_id>  (lines on stdin)
  mkdir -p "$1/proj/sess/subagents/workflows/$2"
  cat >"$1/proj/sess/subagents/workflows/$2/agent-$3.jsonl"
}

# Pin the weights/thresholds by ENV so these assertions never move when
# build.config.sh's defaults are re-tuned (same convention as
# test_pipeline_spend_report.sh's own run() helper).
PINNED_ENV=(SPEND_WEIGHT_INPUT=1 SPEND_WEIGHT_CACHE_READ=0.1 SPEND_WEIGHT_CACHE_CREATE=1.25
            SPEND_WEIGHT_OUTPUT=5 SPEND_MACHINERY_MAX_CALLS=6 SPEND_WORKER_PROFILE_MIN_CALLS=40)

emit() {  # emit <transcript-root> <lake-dir> [args...]
  local root="$1" lake="$2"; shift 2
  env "${PINNED_ENV[@]}" SPEND_TRANSCRIPT_ROOT="$root" ITEM_EFFICIENCY_RAW_DIR="$lake" \
    bash "$EMIT" "$@"
}
spend() {  # spend <transcript-root> [args...]
  local root="$1"; shift
  env "${PINNED_ENV[@]}" bash "$SPEND" --root "$root" --format json "$@"
}

# ===========================================================================
# 0. Fixture corpus: one build run (1 worker at 8 calls + 1 machinery agent at
#    3 calls) and one design run (20 calls).
# ===========================================================================
ROOT="$TMP/corpus"
{
  i=1
  while [ "$i" -le 8 ]; do
    usage_line "req_W$i" "2026-07-10T11:0$((i - 1)):00.000Z" claude-opus-5 500 100 20 4
    i=$((i + 1))
  done
} | mkagent "$ROOT" wf_build-001 w0001
{
  usage_line req_M1 2026-07-10T10:00:00.000Z claude-haiku-4-5 100 0 10 2
  usage_line req_M2 2026-07-10T10:01:00.000Z claude-haiku-4-5 100 0 10 2
  usage_line req_M3 2026-07-10T10:02:00.000Z claude-haiku-4-5 100 0 10 2
} | mkagent "$ROOT" wf_build-001 m0001
{
  i=1
  while [ "$i" -le 20 ]; do
    usage_line "req_D$i" "2026-07-09T09:$(printf '%02d' "$i"):00.000Z" claude-opus-5 900 50 30 6
    i=$((i + 1))
  done
} | mkagent "$ROOT" wf_design-001 d0001

LAKE="$TMP/lake"
REC="$(emit "$ROOT" "$LAKE" --slug demo --repo o/r --epic 923 --issue 943 --pr 1500 \
        --level 1 --build-run wf_build-001 --design-run wf_design-001 \
        --gate-wait-ms 60000 --end-to-end-ms 1800000)"

echo "record shape:"
check "the record is a single valid JSON object" \
  bash -c "printf '%s' '$REC' | jq -e 'type == \"object\"' >/dev/null"
check_eq "schema_version is the string \"1\"" "1" "$(printf '%s' "$REC" | jq -r '.schema_version')"
check_eq "slug is carried verbatim" "demo" "$(printf '%s' "$REC" | jq -r '.slug')"
check_eq "epic is carried as a NUMBER (so a reader can group_by it)" "number" \
  "$(printf '%s' "$REC" | jq -r '.epic | type')"
check_eq "level is carried (the per-LEVEL rollup axis)" "1" "$(printf '%s' "$REC" | jq -r '.level')"
check_eq "the profiler is named as the token source, in-record" "pipeline-spend-report.sh" \
  "$(printf '%s' "$REC" | jq -r '.spend_source')"

# ===========================================================================
# 1. Four phases, each split into output / cache_create / cache_read.
# ===========================================================================
echo "phases:"
for ph in design driver_prep worker mechanical; do
  check "phases.$ph key exists" \
    bash -c "printf '%s' '$REC' | jq -e 'has(\"phases\") and (.phases | has(\"$ph\"))' >/dev/null"
done
for cls in output cache_create cache_read input; do
  check "phases.worker.tokens.$cls is present and numeric (the cheap-cache-read distortion stays visible)" \
    bash -c "printf '%s' '$REC' | jq -e '(.phases.worker.tokens.$cls | type) == \"number\"' >/dev/null"
done
# worker: 8 calls * (500*0.1 + 100*1.25 + 20*5 + 4) = 8 * 279 = 2232
check_eq "phases.worker.units is the hand-computed 2232" "2232" \
  "$(printf '%s' "$REC" | jq -r '.phases.worker.units')"
# machinery: 3 * (100*0.1 + 0 + 10*5 + 2) = 3 * 62 = 186
check_eq "phases.mechanical.units is the hand-computed 186" "186" \
  "$(printf '%s' "$REC" | jq -r '.phases.mechanical.units')"
# design run: 20 * (900*0.1 + 50*1.25 + 30*5 + 6) = 20 * 308.5 -> int() per call
check_eq "phases.design.units reflects the design run alone, not the build run" "6170" \
  "$(printf '%s' "$REC" | jq -r '.phases.design.units')"
check_eq "phases.worker.tokens.cache_read is 8*500" "4000" \
  "$(printf '%s' "$REC" | jq -r '.phases.worker.tokens.cache_read')"

# ===========================================================================
# 2. An UNSUPPLIED phase is null, never 0.
# ===========================================================================
check_eq "an unsupplied phase (driver_prep, no --driver-prep-run) is null, NOT 0 — an unattributed phase is not a free phase" \
  "null" "$(printf '%s' "$REC" | jq -r '.phases.driver_prep')"
NOBUILD="$(emit "$ROOT" "$TMP/lake-nobuild" --slug demo --epic 923 --end-to-end-ms 100)"
check_eq "with NO --build-run, agent_counts.worker follows its phase to null rather than 0" \
  "null" "$(printf '%s' "$NOBUILD" | jq -r '.agent_counts.worker')"
check_eq "...and agent_counts.mechanical likewise" "null" \
  "$(printf '%s' "$NOBUILD" | jq -r '.agent_counts.mechanical')"
check_eq "...while the record still carries its identity and what WAS measured" "923" \
  "$(printf '%s' "$NOBUILD" | jq -r '.epic')"

# ===========================================================================
# 3. THE CENTRAL TEST — composition, not reimplementation.
# ===========================================================================
echo "composition (the load-bearing property):"
PROF="$(spend "$ROOT" --run wf_build-001)"
check_eq "phases.worker.units EQUALS the profiler's own item_workers.units — the emit selects, it never re-derives" \
  "$(printf '%s' "$PROF" | jq -r '.item_workers.units')" \
  "$(printf '%s' "$REC" | jq -r '.phases.worker.units')"
check_eq "phases.mechanical.units EQUALS the profiler's own machinery.units" \
  "$(printf '%s' "$PROF" | jq -r '.machinery.units')" \
  "$(printf '%s' "$REC" | jq -r '.phases.mechanical.units')"
check_eq "agent_counts.worker EQUALS the profiler's item_workers.agents (role counts and role tokens cannot disagree)" \
  "$(printf '%s' "$PROF" | jq -r '.item_workers.agents')" \
  "$(printf '%s' "$REC" | jq -r '.agent_counts.worker')"
check_eq "agent_counts.mechanical EQUALS the profiler's machinery.agents" \
  "$(printf '%s' "$PROF" | jq -r '.machinery.agents')" \
  "$(printf '%s' "$REC" | jq -r '.agent_counts.mechanical')"
check_eq "the raw per-class token split rides through unchanged too (cache_create)" \
  "$(printf '%s' "$PROF" | jq -r '.item_workers.raw_tokens.cache_create')" \
  "$(printf '%s' "$REC" | jq -r '.phases.worker.tokens.cache_create')"

# 3b. The DEDUPE trap must survive composition. One API response split across
#     three transcript lines that each repeat the same usage block: the record
#     must carry the UNDOUBLED (untripled) figure. If this ever reports 3x, the
#     emit stopped composing and started summing lines itself.
DROOT="$TMP/dedupe"
{
  usage_line req_A 2026-07-10T10:00:00.000Z claude-opus-5 1000 200 40 8
  usage_line req_A 2026-07-10T10:00:01.000Z claude-opus-5 1000 200 40 8
  usage_line req_A 2026-07-10T10:00:02.000Z claude-opus-5 1000 200 40 8
} | mkagent "$DROOT" wf_dd-001 dd0001
DREC="$(emit "$DROOT" "$TMP/lake-dd" --slug dd --build-run wf_dd-001)"
# units = 1000*0.1 + 200*1.25 + 40*5 + 8 = 558 (NOT 1674)
check_eq "DEDUPE survives composition: 3 repeated usage lines yield 558 units, never 1674" \
  "558" "$(printf '%s' "$DREC" | jq -r '.phases.mechanical.units')"
check_eq "DEDUPE: the raw cache_read is counted once (1000), not 3x" \
  "1000" "$(printf '%s' "$DREC" | jq -r '.phases.mechanical.tokens.cache_read')"

# ===========================================================================
# 4. Wall-clock: derived, passed through, or honestly null.
# ===========================================================================
echo "wall-clock:"
# The worker agent's own span: 11:00:00 -> 11:07:00 = 420000ms, derived from
# the profiler's item_workers.wall_ms without the caller measuring anything.
check_eq "wall_ms.worker is DERIVED from the profiler's item_workers.wall_ms when --worker-ms is absent" \
  "420000" "$(printf '%s' "$REC" | jq -r '.wall_ms.worker')"
check_eq "...and it agrees with the profiler's own figure" \
  "$(printf '%s' "$PROF" | jq -r '.item_workers.wall_ms')" \
  "$(printf '%s' "$REC" | jq -r '.wall_ms.worker')"
check_eq "wall_ms.gate_wait is passed through verbatim" "60000" \
  "$(printf '%s' "$REC" | jq -r '.wall_ms.gate_wait')"
check_eq "wall_ms.end_to_end is passed through verbatim" "1800000" \
  "$(printf '%s' "$REC" | jq -r '.wall_ms.end_to_end')"
check_eq "an unmeasured CI leg is null, NEVER 0" "null" "$(printf '%s' "$REC" | jq -r '.wall_ms.ci')"
check_eq "an unmeasured merge-group leg is null, NEVER 0" "null" \
  "$(printf '%s' "$REC" | jq -r '.wall_ms.merge_group')"
OVR="$(emit "$ROOT" "$TMP/lake-ovr" --slug demo --build-run wf_build-001 --worker-ms 999)"
check_eq "an explicit --worker-ms WINS over the derived span" "999" \
  "$(printf '%s' "$OVR" | jq -r '.wall_ms.worker')"
BAD="$(emit "$ROOT" "$TMP/lake-bad" --slug demo --build-run wf_build-001 --ci-ms not-a-number)"
check_eq "a non-numeric wall-clock value degrades to null rather than corrupting the record" "null" \
  "$(printf '%s' "$BAD" | jq -r '.wall_ms.ci')"
check "...and the record is still valid JSON" \
  bash -c "printf '%s' '$BAD' | jq -e . >/dev/null"

# 4b. gh-derived CI timing: a stub `gh` on PATH proves the derivation; no gh
#     proves the degradation. Real `gh` is never invoked by this suite.
STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'EOF'
#!/usr/bin/env bash
# fixture gh: two runs on the commit, spanning 10:00:00Z -> 10:04:00Z (240s)
echo '[{"startedAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:03:00Z"},{"startedAt":"2026-07-10T10:01:00Z","updatedAt":"2026-07-10T10:04:00Z"}]'
EOF
chmod +x "$STUBBIN/gh"
GHREC="$(PATH="$STUBBIN:$PATH" emit "$ROOT" "$TMP/lake-gh" --slug demo --repo o/r \
          --build-run wf_build-001 --ci-sha deadbeef)"
check_eq "--ci-sha derives the CI span from gh (max updatedAt - min startedAt = 240000ms)" \
  "240000" "$(printf '%s' "$GHREC" | jq -r '.wall_ms.ci')"
NOREPO="$(PATH="$STUBBIN:$PATH" emit "$ROOT" "$TMP/lake-norepo" --slug demo \
           --build-run wf_build-001 --ci-sha deadbeef 2>/dev/null)"
check_eq "--ci-sha without --repo cannot resolve, so the leg stays null (never guessed)" \
  "null" "$(printf '%s' "$NOREPO" | jq -r '.wall_ms.ci')"
EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
RESTRICTED_PATH="$EMPTYBIN:$(dirname "$(command -v jq)"):/usr/bin:/bin"
if PATH="$RESTRICTED_PATH" command -v gh >/dev/null 2>&1; then
  ok "no-gh arm skipped: gh is reachable even on the restricted PATH on this host (the --repo-less arm above covers the null path)"
else
  NOGH="$(PATH="$RESTRICTED_PATH" emit "$ROOT" "$TMP/lake-nogh" \
           --slug demo --repo o/r --build-run wf_build-001 --ci-sha deadbeef 2>/dev/null)"
  check_eq "with no gh on PATH the CI leg is null and the record still emits" "null" \
    "$(printf '%s' "$NOGH" | jq -r '.wall_ms.ci')"
fi

# ===========================================================================
# 5. Sink behavior.
# ===========================================================================
echo "sink:"
MONTH="$(date -u +%Y-%m)"
check "the record was appended to the monthly lake file" test -s "$LAKE/item-efficiency-${MONTH}.jsonl"
check_eq "one invocation appends exactly one line" "1" "$(wc -l < "$LAKE/item-efficiency-${MONTH}.jsonl" | tr -d ' ')"
PLAKE="$TMP/lake-print"
emit "$ROOT" "$PLAKE" --slug demo --build-run wf_build-001 --print-only >/dev/null
check "--print-only writes NOTHING to the lake" bash -c "! ls '$PLAKE'/item-efficiency-*.jsonl 2>/dev/null | grep . >/dev/null"

# ===========================================================================
# 6. Degradation — warn + null + exit 0, never a crash or a fabricated number.
# ===========================================================================
echo "degradation:"
NOSLUG="$(emit "$ROOT" "$TMP/lake-noslug" --build-run wf_build-001 2>&1; echo "rc=$?")"
check "a missing --slug warns and exits 0 (telemetry never blocks its caller)" \
  bash -c "grep -q 'rc=0' <<<'$NOSLUG'"
check "...and emits no record" bash -c "! grep -q '\"slug\"' <<<'$NOSLUG'"

ORPHAN="$TMP/orphan"
mkdir -p "$ORPHAN"
cp "$EMIT" "$ORPHAN/emit-item-efficiency.sh"
ORPHREC="$(env "${PINNED_ENV[@]}" SPEND_TRANSCRIPT_ROOT="$ROOT" ITEM_EFFICIENCY_RAW_DIR="$TMP/lake-orph" \
            bash "$ORPHAN/emit-item-efficiency.sh" --slug demo --build-run wf_build-001 \
            --end-to-end-ms 5000 2>/dev/null; echo "rc=$?")"
check "with NO profiler reachable the emit still exits 0" \
  bash -c "grep -q 'rc=0' <<<'$ORPHREC'"
ORPHJSON="$(printf '%s' "$ORPHREC" | sed 's/rc=0$//')"
check_eq "...phases degrade to null rather than a locally recomputed substitute (which would fork the dedupe trap)" \
  "null" "$(printf '%s' "$ORPHJSON" | jq -r '.phases.worker')"
check_eq "...and the wall-clock the CALLER measured still survives" "5000" \
  "$(printf '%s' "$ORPHJSON" | jq -r '.wall_ms.end_to_end')"

EMPTYCORPUS="$(emit "$TMP/no-such-corpus" "$TMP/lake-empty" --slug demo --build-run wf_build-001 2>/dev/null; echo "rc=$?")"
check "an empty transcript corpus is not an error (a genuinely fresh install)" \
  bash -c "grep -q 'rc=0' <<<'$EMPTYCORPUS'"
check_eq "...and the phase reports a real, honest ZERO from the profiler (it ran; there was nothing to attribute) rather than null" \
  "0" "$(printf '%s' "$EMPTYCORPUS" | sed 's/rc=0$//' | jq -r '.phases.worker.units')"

# ===========================================================================
# 7. Contract pointers — the sink spec, the README stream doc, the wiring.
# ===========================================================================
echo "contract pointers:"
check "the emit script carries the canonical sink-spec header pointer" \
  grep -q 'canonical sink spec: meta/data/raw/README.md' "$EMIT"
check "meta/data/raw/README.md documents the item-efficiency stream" \
  grep -q 'item-efficiency-<YYYY-MM>.jsonl' "$README"
check "README names emit-item-efficiency.sh as the stream's emit site" \
  grep -q 'emit-item-efficiency.sh' "$README"
check "README gives the stream its own section heading" \
  grep -Fq '### `item-efficiency`' "$README"

# The prose-rot guard: build.md's 4d merge step is the ONLY place a per-item
# efficiency record is emitted, and an LLM-executed markdown step can be
# paraphrased away with no error — the failure mode is an ABSENT record.
# Folded in here rather than shipped as a fourth near-identical
# validate-*-emit.sh script (subtraction over mechanism).
if [ ! -f "$BUILD_MD" ]; then
  bad "build.md wiring" "build.md missing entirely at $BUILD_MD"
else
  check "build.md still invokes emit-item-efficiency.sh (the 4d merge seam)" \
    grep -Fq 'emit-item-efficiency.sh' "$BUILD_MD"
  block="$(grep -A4 -F 'emit-item-efficiency.sh' "$BUILD_MD" || true)"
  if grep -Fq -- '--build-run' <<<"$block"; then
    ok "build.md passes --build-run (without it every token phase is null)"
  else
    bad "build.md passes --build-run" "wiring drifted — the emit would record no tokens"
  fi
  # temperloop#1877: --build-run takes EVERY build-level.mjs invocation for the
  # level (initial + each 3d-esc continuation round), comma-separated — a
  # singular "the wf_ id" reading leaves continuation-round spend unattributed.
  if grep -Fq -- '--build-run <WF[,WF...]' <<<"$block"; then
    ok "build.md's --build-run names the comma-separated multi-invocation form (WF[,WF...])"
  else
    bad "build.md's --build-run names the comma-separated multi-invocation form" \
      "wording drifted back to a single wf id — continuation rounds' spend would go unattributed"
  fi
fi

# The additive profiler fields this metric depends on must not silently
# disappear: they are what makes the phase split possible at all.
check "pipeline-spend-report.sh emits per-class raw_tokens (the field the phase split reads)" \
  bash -c "printf '%s' '$PROF' | jq -e '(.item_workers.raw_tokens.output | type) == \"number\" and (.machinery.raw_tokens.cache_read | type) == \"number\"' >/dev/null"
check "pipeline-spend-report.sh emits per-class wall_ms and api_calls" \
  bash -c "printf '%s' '$PROF' | jq -e '(.item_workers.api_calls | type) == \"number\" and (.item_workers.wall_ms | type) == \"number\"' >/dev/null"
EMPTY_PROF="$(spend "$TMP/no-such-corpus")"
check "...and per-class wall_ms is null (not 0) when no agent carried a parsable timestamp" \
  bash -c "printf '%s' '$EMPTY_PROF' | jq -e '.item_workers.wall_ms == null and .machinery.wall_ms == null' >/dev/null"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_item_efficiency: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_item_efficiency: OK — all %d checks passed\n' "$pass"
