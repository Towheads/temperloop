#!/usr/bin/env bash
#
# test_replay_preflight_derive.sh — the DERIVATION suite for the replay spend
# gate (temperloop#1555, epic #1225 "model comparison harness"). The fourth
# suite over `replay.sh preflight`, and — like its three siblings — a separate
# file because it defends a different failure surface:
#
#   * test_replay_preflight.sh          the PLUMBING (settings read, ceiling
#                                       stops, quota gate consulted, unreadable
#                                       input fails closed)
#   * test_replay_preflight_two_arm.sh  the COUNT units (corpus records vs
#                                       executed replays vs paired outcomes)
#   * test_replay_preflight_cost_unit.sh the COST unit (what a "token" IS, and
#                                       whether the gate and the report mean
#                                       the same thing by it)
#   * THIS FILE                         the PROVENANCE of the per-replay
#                                       number — where it came from, and
#                                       whether the gate says so honestly
#
# ── THE DEFECT THIS PINS ───────────────────────────────────────────────────
# All three sibling suites stayed green while the spend gate authorized
# batches off a figure that observed data contradicted. The per-replay cost
# was ALWAYS the configured REPLAY_PREFLIGHT_TOKENS_PER_REPLAY literal — an
# n=1 order-of-magnitude estimate from a single validation replay. The first
# live batch then executed 14 real replays and measured:
#
#     n=14 · total 9,799,485 · mean 699,963 · range 309,700..1,476,744
#
# i.e. the literal was 1.49x LOW, with a 4.8x spread the constant could not
# express at all. Because the estimate is what the ceiling check and the
# operator confirmation are computed FROM, that understated every batch's
# projected spend by the same factor: at N=21 the gate projected 19.74M
# against a 50M ceiling where the observed mean projects 29.4M — nothing was
# wrongly authorized, but the margin shown was about twice as generous as the
# truth. And nothing consumed the records that said so.
#
# ── WHAT IS ASSERTED, AND HOW ──────────────────────────────────────────────
# Everything below is asserted on REAL EMITTED JSON from `replay.sh preflight`
# — its stdout and its exit code — over a synthetic attribution lake this
# suite writes itself. Never on internal shell state, and never on a grep of
# the SUT's source.
#
# The lake fixture is built from the SPEND_WEIGHT_* values in force, so the
# expected mean/min/max below are computed by this file rather than
# transcribed: an assertion that hard-codes a weighted number would start
# lying the day the weights are retuned, which is the exact class of staleness
# this whole item is about.
#
# Sections:
#   1  FIXTURE 2 (the unmeasured host) — a host with NO observed records
#      reports the configured literal, says it is unmeasured, and NEVER
#      presents the literal as measured
#   2  FIXTURE 1 (the measured host) — a host with enough observed records
#      reports a DERIVED estimate and NAMES n in its basis string
#   3  THE THRESHOLD — REPLAY_PREFLIGHT_DERIVE_MIN_N is a real, named boundary
#      (below it the literal, at it the derivation, 0 forces the literal),
#      + MUTATION PROOF that the estimate genuinely drives the projection
#   4  THE DISPERSION SIGNAL — a single point estimate is never the only thing
#      shown; the same batch is projected at the observed p90 and maximum, and
#      a ceiling the point clears but the p90 does not is SAID OUT LOUD
#   5  THE SOURCE IS FILTERED AND RE-WEIGHTED — foreign seats, token-less
#      records and torn lines do not enter the mean, and the derivation is
#      computed from raw tokens under TODAY'S weights rather than from the
#      records' own stored (possibly stale-epoch) weighted_units
#   6  FAIL-OPEN — an absent/unreadable lake is "no observations", never a
#      CANNOT_EVALUATE: a telemetry path must not be able to stop a spend gate
#
# Hermetic: no `gh` call, no network, no live model call, no replay executed.
# preflight reads a plain corpus JSONL fixture and a plain lake JSONL fixture;
# quota-gate.sh is pointed at a nonexistent cache so it reports "unavailable"
# (fail open) and can never be the reason anything below stops. No mapfile /
# associative arrays / GNU-only flags (bash 3.2).
#
# NOTE FOR THE GATE POOL: section 3's mutation proof edits a $WORK-local COPY
# of replay.sh (temperloop#1421 — never the live tree file), so nothing here
# requires the SERIAL lane its replay siblings sit in for other reasons.
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_preflight_derive.sh
#
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/replay.sh"

# THE MEASUREMENT, transcribed from temperloop#1555 (the first live batch).
# Used only in messages and in the "the literal is low" sanity check below —
# never as an expected output, since this suite derives its expectations from
# its own fixture.
LIVE_N=14
LIVE_MEAN=699963

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-preflight-derive-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# mutate_file <file> <old-literal-text> <new-literal-text> — exact, literal,
# single-occurrence replacement (the twin of the three sibling suites'). Dies
# loudly if the old text is missing or not unique, so a mutation proof can
# never silently degrade into a no-op that "passes".
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts
# (the same helper, and the same rationale, as the sibling suites'), so a
# mutation proof can edit ONE real copy of replay.sh without ever writing
# into the checkout.
mk_mirror() {
  local d="$1" f b
  mkdir -p "$d/workflows/scripts/model-comparison"
  for f in "$SCRIPTS_DIR"/*; do
    b="$(basename "$f")"
    [ "$b" = "model-comparison" ] && continue
    ln -s "$f" "$d/workflows/scripts/$b"
  done
  for f in "$MC_DIR"/*; do
    ln -s "$f" "$d/workflows/scripts/model-comparison/$(basename "$f")"
  done
}

unlink_and_copy() {
  local p="$1" target real
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# mk_corpus <file> <n-eligible> — n eligible corpus records, exactly as
# `corpus` emits them.
mk_corpus() {
  local file="$1" n="$2" i=1
  : >"$file"
  while [ "$i" -le "$n" ]; do
    jq -cn --argjson pr "$i" '{pr:$pr, status:"eligible"}' >>"$file"
    i=$((i + 1))
  done
}

# mk_lake_record <seat> <usage-source> <input> <output> <cache-read> <cache-creation>
# One emit-model-usage.sh-shaped attribution record. `unavailable` records
# carry a null token block by that script's own contract.
mk_lake_record() {
  local seat="$1" src="$2"
  if [ "$src" = "unavailable" ]; then
    jq -cn --arg seat "$seat" \
      '{schema_version:"1", ts:"2026-08-01T00:00:00Z", session_id:null, repo:null,
        seat:$seat, model:"m", provider:null, usage_source:"unavailable",
        tokens:null, weighted_units:null, duration_ms:null, outcome_ref:"pr:1"}'
    return 0
  fi
  jq -cn --arg seat "$seat" --argjson i "$3" --argjson o "$4" --argjson cr "$5" --argjson cc "$6" \
    '{schema_version:"1", ts:"2026-08-01T00:00:00Z", session_id:null, repo:null,
      seat:$seat, model:"m", provider:"anthropic", usage_source:"cli-envelope",
      tokens:{input:$i, output:$o, cache_read:$cr, cache_creation:$cc},
      weighted_units:999999999, duration_ms:1000, outcome_ref:"pr:1"}'
}

# THE WEIGHTS IN FORCE — read from the same config the SUT reads, so every
# expected figure below is derived rather than transcribed. A hard-coded
# weighted number here would silently become a lie at the next SPEND_WEIGHT_*
# retune, which is precisely the staleness class this item exists to close.
# shellcheck source=../../build/build.config.sh
. "$SCRIPTS_DIR/build/build.config.sh"

# weigh <input> <output> <cache-read> <cache-creation> — the SPEND_WEIGHT_*
# multiply-add, floored. jq does the arithmetic (the weights are fractional).
weigh() {
  jq -n --argjson i "$1" --argjson o "$2" --argjson cr "$3" --argjson cc "$4" \
    --argjson wi "$SPEND_WEIGHT_INPUT" --argjson wo "$SPEND_WEIGHT_OUTPUT" \
    --argjson wcr "$SPEND_WEIGHT_CACHE_READ" --argjson wcc "$SPEND_WEIGHT_CACHE_CREATE" \
    '((($i * $wi) + ($o * $wo) + ($cr * $wcr) + ($cc * $wcc)) | floor)'
}

NOCACHE="$WORK/no-such-quota-cache.json"

# pf <env-assignments...> — preflight with the quota gate deterministically
# "unavailable" (fail open: it can never be the reason anything here stops).
pf() {
  env BUILD_QUOTA_CACHE="$NOCACHE" "$@"
}

CORPUS="$WORK/corpus.jsonl"
mk_corpus "$CORPUS" 3          # 3 records x 2 arms = 6 executed replays
PLANNED_REPLAYS=6

# ── THE LAKE FIXTURES ──────────────────────────────────────────────────────
# EMPTY_LAKE  a host that has never executed a replay.
# FULL_LAKE   a host with 6 observed replay-candidate records whose costs are
#             DELIBERATELY spread wide (the real distribution spans 4.8x), so
#             the dispersion assertions below have something to measure.
EMPTY_LAKE="$WORK/lake-empty"; mkdir -p "$EMPTY_LAKE"
FULL_LAKE="$WORK/lake-full"; mkdir -p "$FULL_LAKE"

# Six records: cache_read 1M..6M, everything else fixed. Under any positive
# weight vector this is a monotonically increasing, evenly spaced cost series,
# so mean = the middle of the range and the arithmetic below stays exact.
FULL_LAKE_FILE="$FULL_LAKE/model-usage-2026-08.jsonl"
: >"$FULL_LAKE_FILE"
for cr in 1000000 2000000 3000000 4000000 5000000 6000000; do
  mk_lake_record replay-candidate cli-envelope 100 1000 "$cr" 0 >>"$FULL_LAKE_FILE"
done
OBS_MIN="$(weigh 100 1000 1000000 0)"
OBS_MAX="$(weigh 100 1000 6000000 0)"
OBS_MEAN="$(jq -n --argjson lo "$OBS_MIN" --argjson hi "$OBS_MAX" '(($lo + $hi) / 2) | floor')"
OBS_N=6

[ "$OBS_MIN" -lt "$OBS_MAX" ] || fail "fixture is degenerate: min $OBS_MIN is not below max $OBS_MAX"

echo "# fixture: $OBS_N observed replays, weighted $OBS_MIN..$OBS_MAX, mean $OBS_MEAN"
echo "# (the live measurement this item is grounded in: n=$LIVE_N, mean $LIVE_MEAN)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1 — FIXTURE 2: a host with NO observed records.
#
# The behaviour here must be UNCHANGED from before the derivation existed:
# the configured literal, used and labelled as such. The one thing it must
# never do is present that literal as a measurement — an invented
# "measurement" is worse than an honest estimate, because it is the kind of
# number a reader stops questioning.
# ═══════════════════════════════════════════════════════════════════════════
count
out_empty="$(pf MODEL_USAGE_RAW_DIR="$EMPTY_LAKE" bash "$SUT" preflight --corpus-file "$CORPUS")"
rc_empty=$?
[ "$rc_empty" -eq 0 ] || fail "1: preflight on an unmeasured host should exit 0, got $rc_empty: $out_empty"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_empty")" = "configured-literal" ] \
  || fail "1: an unmeasured host must report the configured-literal mode, got: $(jq -c '{tokens_per_replay_mode,tokens_per_replay_estimate}' <<<"$out_empty")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_empty")" = "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" ] \
  || fail "1: an unmeasured host must fall back to REPLAY_PREFLIGHT_TOKENS_PER_REPLAY ($REPLAY_PREFLIGHT_TOKENS_PER_REPLAY), got $(jq -r .tokens_per_replay_estimate <<<"$out_empty")"
[ "$(jq -r '.estimated_total_tokens' <<<"$out_empty")" = "$((PLANNED_REPLAYS * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY))" ] \
  || fail "1: the projection must be the literal over every executed replay, got: $(jq -c '{planned_replays_n,estimated_total_tokens}' <<<"$out_empty")"
ok "1a FIXTURE 2: a host with no observed records reports the configured literal, unchanged"

count
[ "$(jq -r '.observed_replay_cost.records_n' <<<"$out_empty")" = "0" ] \
  || fail "1b: an unmeasured host should report 0 observed records: $(jq -c .observed_replay_cost <<<"$out_empty")"
[ "$(jq -r '.observed_replay_cost.sufficient_to_derive' <<<"$out_empty")" = "false" ] \
  || fail "1b: sufficient_to_derive must be false with no records"
jq -e '(.observed_replay_cost.insufficient_reason | type) == "string"
       and ((.observed_replay_cost.insufficient_reason | length) > 0)' >/dev/null <<<"$out_empty" \
  || fail "1b: the absence of observations must be a NAMED reason, not a bare null: $(jq -c .observed_replay_cost <<<"$out_empty")"
ok "1b the absence of observations is stated positively, with a named reason"

# THE CENTRAL HONESTY ASSERTION. The basis string must say the number is
# unmeasured, and must not claim a derivation it did not do.
count
basis_empty="$(jq -r .tokens_per_replay_basis <<<"$out_empty")"
case "$basis_empty" in
  *UNMEASURED*) : ;;
  *) fail "1c: the basis string on an unmeasured host must say so: $basis_empty" ;;
esac
case "$basis_empty" in
  *DERIVED\ from*) fail "1c: the basis string claims a derivation on a host with no records: $basis_empty" ;;
esac
jq -e '(.tokens_per_replay_basis | test("(?i)estimate"))
       and (.tokens_per_replay_basis | test("n=1"))
       and (.tokens_per_replay_basis | test("NOT derived"))' >/dev/null <<<"$out_empty" \
  || fail "1c: the fallback basis must keep its n=1 provenance disclosure: $basis_empty"
ok "1c the basis string says the figure is UNMEASURED and never presents the literal as measured"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 — FIXTURE 1: a host with enough observed records.
# ═══════════════════════════════════════════════════════════════════════════
count
out_full="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5 \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
rc_full=$?
[ "$rc_full" -eq 0 ] || fail "2: preflight on a measured host should exit 0, got $rc_full: $out_full"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_full")" = "derived-from-observed-records" ] \
  || fail "2: a measured host must report the derived mode, got: $(jq -c '{tokens_per_replay_mode,tokens_per_replay_estimate}' <<<"$out_full")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_full")" = "$OBS_MEAN" ] \
  || fail "2: the derived figure should be the observed mean ($OBS_MEAN), got $(jq -r .tokens_per_replay_estimate <<<"$out_full")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_full")" != "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" ] \
  || fail "2: the derived figure is indistinguishable from the literal — this fixture proves nothing"
[ "$(jq -r .configured_tokens_per_replay <<<"$out_full")" = "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" ] \
  || fail "2: the configured literal must still be published alongside the derived figure"
ok "2a FIXTURE 1: a host with sufficient observed records reports a DERIVED estimate ($OBS_MEAN, not the $REPLAY_PREFLIGHT_TOKENS_PER_REPLAY literal)"

count
basis_full="$(jq -r .tokens_per_replay_basis <<<"$out_full")"
case "$basis_full" in
  *"n=$OBS_N"*) : ;;
  *) fail "2b: the derived basis string must NAME n (expected n=$OBS_N): $basis_full" ;;
esac
case "$basis_full" in
  *DERIVED*) : ;;
  *) fail "2b: the derived basis string must say it is derived: $basis_full" ;;
esac
case "$basis_full" in
  *UNMEASURED*) fail "2b: the derived basis string calls itself unmeasured: $basis_full" ;;
esac
[ "$(jq -r '.observed_replay_cost.records_n' <<<"$out_full")" = "$OBS_N" ] \
  || fail "2b: observed_replay_cost.records_n should be $OBS_N: $(jq -c .observed_replay_cost <<<"$out_full")"
ok "2b the derived basis string NAMES n ($OBS_N) and identifies the mode that produced the number"

# The projection must actually be computed from the derived figure — a mode
# label over an unchanged projection would be a cosmetic fix.
count
[ "$(jq -r .estimated_total_tokens <<<"$out_full")" = "$((PLANNED_REPLAYS * OBS_MEAN))" ] \
  || fail "2c: the projection must be the DERIVED figure over every executed replay ($PLANNED_REPLAYS x $OBS_MEAN), got: $(jq -c '{planned_replays_n,tokens_per_replay_estimate,estimated_total_tokens}' <<<"$out_full")"
[ "$(jq -r .estimated_cost <<<"$out_full")" = "$(jq -r .estimated_total_tokens <<<"$out_full")" ] \
  || fail "2c: estimated_cost and estimated_total_tokens must stay the same figure"
ok "2c the ceiling check and the operator confirmation are computed from the DERIVED figure, not merely labelled with it"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3 — THE THRESHOLD is a real, named boundary.
# ═══════════════════════════════════════════════════════════════════════════
count
out_below="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=$((OBS_N + 1)) \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_below")" = "configured-literal" ] \
  || fail "3a: $OBS_N records below a threshold of $((OBS_N + 1)) must NOT derive: $(jq -c '{tokens_per_replay_mode,tokens_per_replay_estimate}' <<<"$out_below")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_below")" = "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" ] \
  || fail "3a: below the threshold the literal must be in force"
jq -e '(.observed_replay_cost.insufficient_reason | test("REPLAY_PREFLIGHT_DERIVE_MIN_N"))' >/dev/null <<<"$out_below" \
  || fail "3a: the refusal to derive must NAME the setting that caused it: $(jq -c .observed_replay_cost <<<"$out_below")"
ok "3a below REPLAY_PREFLIGHT_DERIVE_MIN_N the literal stays in force, and the reason names the setting"

count
out_at="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N="$OBS_N" \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_at")" = "derived-from-observed-records" ] \
  || fail "3b: exactly-at-threshold must derive (the bound is >=, not >): $(jq -c '{tokens_per_replay_mode}' <<<"$out_at")"
ok "3b exactly at REPLAY_PREFLIGHT_DERIVE_MIN_N the derivation engages (the bound is inclusive)"

count
out_zero="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=0 \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_zero")" = "configured-literal" ] \
  || fail "3c: a threshold of 0 must force the literal (its documented disable value): $(jq -c '{tokens_per_replay_mode}' <<<"$out_zero")"
ok "3c REPLAY_PREFLIGHT_DERIVE_MIN_N=0 forces the configured literal, as documented"

# A non-integer threshold is the temperloop#1365 class: the derivation decision
# it feeds is arithmetic, and an indeterminate one must read as "could not
# evaluate", never as "evaluated, and fine".
count
rc_bad=0
out_bad="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5x \
  bash "$SUT" preflight --corpus-file "$CORPUS" 2>/dev/null)" || rc_bad=$?
[ "$rc_bad" -ne 0 ] || fail "3d: a non-integer REPLAY_PREFLIGHT_DERIVE_MIN_N must fail closed, got exit 0: $out_bad"
[ "$(jq -r '.outcome' <<<"$out_bad" 2>/dev/null)" = "CANNOT_EVALUATE" ] \
  || fail "3d: expected CANNOT_EVALUATE, got: $out_bad"
ok "3d a non-integer REPLAY_PREFLIGHT_DERIVE_MIN_N is CANNOT_EVALUATE, never a silently-literal run"

# MUTATION PROOF — a gate that kept using the literal while still labelling
# itself "derived" would pass every label assertion above. Force that shape
# on a $WORK-local copy and section 2c must fail on it.
count
MUT="$WORK/mut-literal"; mk_mirror "$MUT"
MUT_SUT="$MUT/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$MUT_SUT"
mutate_file "$MUT_SUT" \
  '  local est_tokens=$(( planned_replays * tokens_per_replay ))' \
  '  local est_tokens=$(( planned_replays * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY ))'
mut_out="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5 \
  bash "$MUT_SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r .tokens_per_replay_mode <<<"$mut_out")" = "derived-from-observed-records" ] \
  || fail "3e: the mutation did not preserve the derived LABEL, so it is not the failure shape 2c defends against"
[ "$(jq -r .estimated_total_tokens <<<"$mut_out")" != "$((PLANNED_REPLAYS * OBS_MEAN))" ] \
  || fail "3e: the mutation proof did not fire — a projection off the literal still matched the derived expectation"
ok "3e MUTATION PROOF: a 'derived'-labelled gate still projecting off the literal is caught — 2c is a measurement, not a label check"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4 — THE DISPERSION SIGNAL.
#
# The observed spread is wide (4.8x live), so a bare point estimate is a
# materially misleading thing to authorize spend against: a corpus weighted
# toward large records can cost well above the projection while every number
# on screen still reads fine. The requirement is that a single point estimate
# is not the only thing shown.
# ═══════════════════════════════════════════════════════════════════════════
count
jq -e '.estimated_total_tokens_range.available == true' >/dev/null <<<"$out_full" \
  || fail "4a: a derived run must publish a dispersion range: $(jq -c .estimated_total_tokens_range <<<"$out_full")"
[ "$(jq -r '.estimated_total_tokens_range.high_total_at_observed_p90' <<<"$out_full")" = "$(jq -rn --argjson p "$(jq -r '.observed_replay_cost.p90' <<<"$out_full")" --argjson n "$PLANNED_REPLAYS" '$p * $n')" ] \
  || fail "4a: the p90 projection is not p90 x planned replays: $(jq -c .estimated_total_tokens_range <<<"$out_full")"
[ "$(jq -r '.estimated_total_tokens_range.high_total_at_observed_max' <<<"$out_full")" = "$((OBS_MAX * PLANNED_REPLAYS))" ] \
  || fail "4a: the max projection is not max x planned replays"
[ "$(jq -r '.estimated_total_tokens_range.high_total_at_observed_max' <<<"$out_full")" -gt "$(jq -r '.estimated_total_tokens' <<<"$out_full")" ] \
  || fail "4a: the high projection is not above the point projection — there is no dispersion signal here"
ok "4a the projection carries a dispersion signal: the same batch at the observed p90 and maximum, not a bare mean"

count
jq -e '(.observed_replay_cost.min | type) == "number"
       and (.observed_replay_cost.p50 | type) == "number"
       and (.observed_replay_cost.p90 | type) == "number"
       and (.observed_replay_cost.max | type) == "number"
       and (.observed_replay_cost.stddev | type) == "number"
       and (.observed_replay_cost.spread_ratio | type) == "number"' >/dev/null <<<"$out_full" \
  || fail "4b: the observed distribution is not published: $(jq -c .observed_replay_cost <<<"$out_full")"
[ "$(jq -r '.observed_replay_cost.min' <<<"$out_full")" = "$OBS_MIN" ] \
  || fail "4b: observed min should be $OBS_MIN"
[ "$(jq -r '.observed_replay_cost.max' <<<"$out_full")" = "$OBS_MAX" ] \
  || fail "4b: observed max should be $OBS_MAX"
case "$basis_full" in
  *"$OBS_MIN"*"$OBS_MAX"*) : ;;
  *) fail "4b: the basis string does not state the observed range: $basis_full" ;;
esac
ok "4b the whole observed distribution (min/p50/p90/max/stddev/spread) is published, and the basis states the range"

# The case that matters: a batch that clears the ceiling at the mean but would
# breach it at the observed p90. Before #1555 there was no way to say that at
# all. The ceiling is set between the two projections so the disclosure has to
# do real work.
count
ceil_between=$(( (PLANNED_REPLAYS * OBS_MEAN + OBS_MAX * PLANNED_REPLAYS) / 2 ))
out_thin="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5 \
  REPLAY_PREFLIGHT_CEILING_TOKENS="$ceil_between" bash "$SUT" preflight --corpus-file "$CORPUS")"
rc_thin=$?
[ "$rc_thin" -eq 0 ] || fail "4c: the point estimate clears this ceiling, so the gate must not stop: exit $rc_thin, $out_thin"
[ "$(jq -r .stop <<<"$out_thin")" = "false" ] \
  || fail "4c: the STOP decision must stay the point estimate's — a worst-case projection is a disclosure, not an enforcement: $(jq -c '{stop,stop_reason}' <<<"$out_thin")"
[ "$(jq -r '.estimated_total_tokens_range.exceeds_ceiling_at_point' <<<"$out_thin")" = "false" ] \
  || fail "4c: fixture is wrong — the point estimate should clear this ceiling"
[ "$(jq -r '.estimated_total_tokens_range.exceeds_ceiling_at_max' <<<"$out_thin")" = "true" ] \
  || fail "4c: the max projection should breach this ceiling: $(jq -c .estimated_total_tokens_range <<<"$out_thin")"
jq -e '.estimated_total_tokens_range.statement | test("(?i)ceiling")' >/dev/null <<<"$out_thin" \
  || fail "4c: the thin-headroom case must be SAID, not merely computable: $(jq -r '.estimated_total_tokens_range.statement' <<<"$out_thin")"
ok "4c a ceiling the mean clears but the observed worst case does not is said out loud — and does NOT stop the batch"

count
jq -e '.estimated_total_tokens_range.available == false
       and ((.estimated_total_tokens_range.unavailable_reason | type) == "string")' >/dev/null <<<"$out_empty" \
  || fail "4d: an unmeasured host must say WHY no dispersion is available, not silently omit it: $(jq -c .estimated_total_tokens_range <<<"$out_empty")"
ok "4d an unmeasured host states that no dispersion exists, rather than omitting the range silently"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 5 — THE SOURCE IS FILTERED, AND RE-WEIGHTED UNDER TODAY'S WEIGHTS.
# ═══════════════════════════════════════════════════════════════════════════
# A lake with the same six replay-candidate records PLUS noise that must not
# enter the mean: another seat's records, an attribution-only record with no
# token block (a missing measurement, never a measurement of zero), and a
# torn line.
count
NOISY_LAKE="$WORK/lake-noisy"; mkdir -p "$NOISY_LAKE"
cp "$FULL_LAKE_FILE" "$NOISY_LAKE/model-usage-2026-08.jsonl"
{ mk_lake_record retro-judge cli-envelope 1 1 1 1
  mk_lake_record pipeline-drive-merge cli-envelope 999999999 999999999 999999999 999999999
  mk_lake_record replay-candidate unavailable 0 0 0 0
} >>"$NOISY_LAKE/model-usage-2026-08.jsonl"
printf '{"seat":"replay-candidate","usage_source":"cli-envelope",\n' >>"$NOISY_LAKE/model-usage-2026-08.jsonl"
out_noisy="$(pf MODEL_USAGE_RAW_DIR="$NOISY_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5 \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r '.observed_replay_cost.records_n' <<<"$out_noisy")" = "$OBS_N" ] \
  || fail "5a: foreign-seat / token-less / torn records leaked into the observed set: $(jq -c .observed_replay_cost <<<"$out_noisy")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_noisy")" = "$OBS_MEAN" ] \
  || fail "5a: the derived mean moved when noise was added — the filter is not doing its job"
[ "$(jq -r '.observed_replay_cost.unparseable_lines_n' <<<"$out_noisy")" = "1" ] \
  || fail "5a: the torn line must be COUNTED, not silently swallowed: $(jq -c .observed_replay_cost <<<"$out_noisy")"
ok "5a only replay-candidate cli-envelope records with a token block enter the mean; a torn line is skipped AND counted"

# The records carry a deliberately absurd stored `weighted_units` (999999999).
# If the derivation read that field instead of re-weighting the raw tokens,
# the mean above could not possibly have matched — so 5a already proves the
# re-weighting, and this asserts the property directly for a reader.
count
[ "$(jq -r '.observed_replay_cost.mean' <<<"$out_noisy")" != "999999999" ] \
  || fail "5b: the derivation read the records' stored weighted_units instead of re-weighting their raw tokens"
[ "$(jq -r '.observed_replay_cost.mean' <<<"$out_noisy")" = "$OBS_MEAN" ] \
  || fail "5b: the mean is not the re-weighted figure"
ok "5b the derivation re-weights each record's RAW tokens under today's SPEND_WEIGHT_* — never its stored, possibly stale-epoch weighted_units"

# Retune-independence, measured: double every weight and the derived figure
# must move with it. A derivation that read stored weighted_units would not.
count
out_retune="$(pf MODEL_USAGE_RAW_DIR="$FULL_LAKE" REPLAY_PREFLIGHT_DERIVE_MIN_N=5 \
  SPEND_WEIGHT_INPUT=2 SPEND_WEIGHT_CACHE_READ=0.2 SPEND_WEIGHT_CACHE_CREATE=2.5 SPEND_WEIGHT_OUTPUT=10 \
  bash "$SUT" preflight --corpus-file "$CORPUS")"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out_retune")" = "$((OBS_MEAN * 2))" ] \
  || fail "5c: doubling every weight should double the derived figure (expected $((OBS_MEAN * 2))), got $(jq -r .tokens_per_replay_estimate <<<"$out_retune")"
ok "5c doubling the SPEND_WEIGHT_* values doubles the derived figure — the derivation is retune-independent by construction"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 6 — FAIL OPEN on the telemetry path.
#
# The rest of this module is fail-CLOSED, deliberately. The lake read is the
# one place that must NOT be: an absent or unreadable telemetry directory is
# "this host has observed nothing", which has a safe and honest answer (use
# the literal, say it is unmeasured). Refusing to price a batch because a
# telemetry directory is missing would let a log path stop a spend gate.
# ═══════════════════════════════════════════════════════════════════════════
count
out_nodir="$(pf MODEL_USAGE_RAW_DIR="$WORK/no-such-lake-dir" bash "$SUT" preflight --corpus-file "$CORPUS")"
rc_nodir=$?
[ "$rc_nodir" -eq 0 ] || fail "6a: an absent lake dir must not stop the gate, got exit $rc_nodir: $out_nodir"
[ "$(jq -r .outcome <<<"$out_nodir")" = "PREFLIGHT" ] \
  || fail "6a: an absent lake dir produced a non-PREFLIGHT outcome: $out_nodir"
[ "$(jq -r .tokens_per_replay_mode <<<"$out_nodir")" = "configured-literal" ] \
  || fail "6a: an absent lake dir must fall back to the literal"
ok "6a an absent attribution lake is 'no observations', never a CANNOT_EVALUATE — a telemetry path cannot stop a spend gate"

count
UNREADABLE_LAKE="$WORK/lake-unreadable"; mkdir -p "$UNREADABLE_LAKE"
cp "$FULL_LAKE_FILE" "$UNREADABLE_LAKE/model-usage-2026-08.jsonl"
chmod 000 "$UNREADABLE_LAKE/model-usage-2026-08.jsonl" 2>/dev/null || true
out_unread="$(pf MODEL_USAGE_RAW_DIR="$UNREADABLE_LAKE" bash "$SUT" preflight --corpus-file "$CORPUS")"
rc_unread=$?
chmod 644 "$UNREADABLE_LAKE/model-usage-2026-08.jsonl" 2>/dev/null || true
[ "$rc_unread" -eq 0 ] || fail "6b: an unreadable lake file must not stop the gate, got exit $rc_unread: $out_unread"
[ "$(jq -r .outcome <<<"$out_unread")" = "PREFLIGHT" ] \
  || fail "6b: an unreadable lake file produced a non-PREFLIGHT outcome: $out_unread"
ok "6b an unreadable lake file degrades to the literal arm rather than refusing to price the batch"

echo
echo "test_replay_preflight_derive.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
