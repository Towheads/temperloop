#!/usr/bin/env bash
#
# judge.sh — the JUDGE pass (temperloop#1259, epic #1225 "model comparison
# harness"). Scores an already-executed `replay-record-v1` record (the
# record `replay.sh execute` + `score.sh score` produce, temperloop#1258)
# with a strong-tier JUDGE model, and attaches the result as a `judge`
# sub-object. This file does NOT reimplement replay execution, corpus
# selection, or the mechanical N/T/X/R diff scoring — it consumes a record
# those already produced (must carry a populated `.candidate.model`) and
# adds a second, model-rendered quality assessment next to the mechanical
# one score.sh already computed.
#
# ── THE STRUCTURAL GUARANTEE THIS FILE OWNS: judge ≠ candidate ────────────
# Before any judge model is ever invoked, this file compares the judge's own
# provider+model against the record's `.candidate.provider`/`.candidate.model`
# and REFUSES (exit 2, outcome "REFUSED") on an exact match — no spend, no
# call, no score. This is a SELF-GRADING guard ONLY. Read that scoping
# precisely, because overclaiming it is the specific failure this item exists
# to avoid (a sibling item in this epic shipped a header asserting a property
# its code did not have, and it took a reviewer to catch): the guard does
# NOT, and cannot, neutralize model-family style bias — a judge from the same
# lineage as the candidate (a different tier of the same family) may still
# share stylistic priors. Rotating judge families to mitigate THAT is a
# separate, explicitly out-of-scope item (temperloop#1260, "judge-rotation-
# mode"). No comment, doc line, or emitted record field in this file may
# claim the guard does more than prevent an exact judge==candidate match —
# rubric.md's own "What this guard does and does not mean" section carries
# the same disclaimer for the model being asked to self-report on it.
#
# ── THE LIVE-CALL TRAP (same shape as replay.sh execute, temperloop#1258) ──
# `judge`/`judge-batch` are the only commands here that can reach a model,
# and neither can reach one by accident. The caller must pass EITHER
# `--judge-runner <cmd>` (a recorded/stubbed runner — how every fixture
# drives this file) OR the explicit `--live` flag (the real
# candidate-session.sh spawn, reused verbatim — the judge routes through the
# SAME containment overlay, provider-key health check, and disclose-before-
# send machinery a candidate replay does, never a second implementation of
# any of the three). With neither, this file prints CANNOT_EVALUATE and
# exits non-zero; there is no implicit fallback to a `claude` on PATH.
#
# ── THE RUBRIC IS PROMPT CONTENT, NEVER A RUNTIME AGENT DISPATCH ──────────
# rubric.md is read with a plain `cat` into the prompt file this script
# builds — byte-for-byte prose, nothing templated or executed. This file
# never invokes the `Task`/`Agent` tool, never references a
# `claude/agents/reviewers/*.md` charter at RUNTIME (they were read ONCE, at
# rubric-authoring time, as prompt source material — see rubric.md's own
# header), and never shells out more than the ONE judge-model call per
# record. The judge call is a plain `claude -p --output-format json`
# invocation (or its recorded-runner stand-in) — structurally indistinguishable
# from any other single-shot headless spawn in this repo.
#
# ── FAIL-CLOSED (temperloop#1365 class) — never a score it did not obtain ──
# Every terminal state below is deliberately distinguishable so a scored
# "0" (a real, considered judgment) is NEVER confused with "the judge could
# not be reached" (a transport/parse failure). Four terminal states:
#
#   exit 0  JUDGED — `judge.outcome` is "JUDGED", `judge.scored` is true,
#           and `judge.quality_score` carries the model's own number
#           (0-100, inclusive of a genuine 0 — a low score honestly
#           computed is never withheld).
#   exit 1  CANNOT_EVALUATE — malformed/absent/unreadable input (the record
#           file, the rubric file, the records-file for a batch), or the
#           record carries no `.candidate.model` to guard against. NO
#           `judge` sub-object is emitted for a single `judge` call; for
#           `judge-batch` this ONE row is emitted AS ITS ORIGINAL RECORD
#           carrying a judgment-absent `judge` sub-object and the batch
#           continues (never a silent drop, and — since temperloop#1556 —
#           never a REPLACEMENT of the row either; see `judge-batch` and
#           § THE BATCH OUTPUT IS THE INPUT, ANNOTATED below), while an
#           unreadable/absent/empty RECORDS FILE itself still
#           CANNOT_EVALUATEs the whole batch (there is nothing to iterate).
#   exit 2  REFUSED — the judge≠candidate guard fired. NO judge sub-object
#           is emitted (no call was ever made) — the bare record's `judge`
#           key is left absent, distinguishable from a null/zero score.
#   exit 4  UNAVAILABLE — the judge model COULD have been called (the guard
#           passed) but the call itself failed: the runner/spawn errored or
#           timed out, the envelope was unparseable, the vendor reported an
#           error, the envelope carried no usable token block, or the
#           model's response was not the contracted JSON shape. The record
#           IS still emitted (never dropped) with `judge.scored:false`,
#           `judge.quality_score:null`, and a NAMED `judge.degradation_notice`
#           — structurally distinct from `judge.scored:true,
#           judge.quality_score:0`, which is a real judgment.
#
# ── Usage ────────────────────────────────────────────────────────────────
#   judge.sh judge --record <replay-record-file> [--rubric <path>] \
#       ( --judge-runner <cmd> | --live ) [--model <id>] [--provider <name>] \
#       [--out <file>] [--prompt-out <file>] [--repo <owner/repo>]
#       Judges ONE record (must carry `.candidate.model`/`.candidate.provider`
#       populated — i.e. run this after `replay.sh execute`). `--rubric`
#       defaults to this directory's own rubric.md. `--judge-runner` takes a
#       command string invoked as `<cmd> <prompt-file>` (the same
#       command-string convention as `replay.sh execute`'s
#       `--candidate-runner`, minus the worktree argument — the judge never
#       touches a worktree). Prints the merged record (JUDGED/UNAVAILABLE) or
#       a bare REFUSED/CANNOT_EVALUATE object per the exit-code table above.
#
#   judge.sh judge-batch --records-file <jsonl> [--rubric <path>] \
#       ( --judge-runner <cmd> | --live ) [--model <id>] [--provider <name>] \
#       [--out <file>] [--repo <owner/repo>]
#       Judges every record in a JSONL file, one call per line, and NEVER
#       aborts the batch on one row's REFUSED/UNAVAILABLE/CANNOT_EVALUATE
#       outcome — every INPUT line produces exactly one OUTPUT line, in
#       order, so a judge that becomes unavailable mid-batch degrades only
#       the affected rows rather than losing the rest of the run. Exit 0 iff
#       every row either reached JUDGED or was unjudgeable BY CONSTRUCTION
#       (see below); exit 4 if at least one row genuinely degraded (REFUSED,
#       UNAVAILABLE, or a malformed individual row) but the batch itself
#       ran; exit 1 CANNOT_EVALUATE only when the records FILE itself is
#       absent/unreadable/empty — nothing to iterate at all.
#
# ── THE BATCH OUTPUT IS THE INPUT, ANNOTATED (temperloop#1556) ─────────────
# `judge-batch` is an ANNOTATING transform, never a replacing one. Its output
# stream is "the input records, judged", NEVER "the input records, with any
# unjudgeable one swapped for an error object". Two rules make that literal:
#
#   1. NO INPUT RECORD IS EVER DROPPED OR OVERWRITTEN. A row the judge could
#      not judge is emitted as ITS ORIGINAL RECORD with a judgment-absent
#      marker attached — a `judge` sub-object carrying `scored:false`,
#      `quality_score:null` and a NAMED `degradation_notice` (the same shape
#      the UNAVAILABLE path already used), never `_je_one_record`'s bare
#      `{"outcome":"CANNOT_EVALUATE",...}` / REFUSED envelope standing in for
#      the record. (An input LINE that is not a JSON object at all cannot
#      carry a merged field, so it is preserved verbatim in the emitted
#      envelope's own `original_line` instead — still one output line per
#      input line, still nothing lost.) The defect this fixes destroyed 14 of
#      21 records per arm on the first live batch and, because a bare error
#      object carries no `.candidate`, took `score.sh aggregate` and the
#      whole comparison report down with it.
#   2. UNJUDGEABLE BY CONSTRUCTION IS NOT A FAILURE. An integration-error
#      record (replay.sh's `_exec_integration_error` shape: `.candidate
#      .outcome == "integration-error"`, no `.candidate.model`, an empty
#      score) is the EXPECTED shape of a failed replay leg — there is no
#      candidate diff to judge and there never was. Such a row is passed
#      through UNJUDGED with a top-level `unjudged` marker, spends no judge
#      call, and contributes NO per-row failure to the degraded tally, so a
#      batch whose only "failures" were never-judgeable rows exits 0 and
#      `judge.degraded` stops firing on it. The marker is deliberately NOT a
#      `judge` sub-object: the comparison report counts a record with no
#      `judge.outcome` as unjudged, which is exactly what it is, rather than
#      listing it as a judge degradation it never was.
#
#   judge.sh judge-rotate --record <file> --judges <provider:model,provider:model,...> \
#       [--rubric <path>] ( --judge-runner <cmd> | --live ) [--model <id>] \
#       [--out <file>] [--repo <owner/repo>]
#       OPTIONAL, OFF BY DEFAULT (see § OPTIONAL CROSS-FAMILY JUDGE ROTATION
#       above). Scores ONE record with EVERY judge named in `--judges` (a
#       comma-separated list of two or more `provider:model` pairs spanning
#       more than one provider family) via the exact same `_je_one_record`
#       the single-judge path uses, then reports the VARIANCE of the
#       resulting quality_score across the panel members that reached
#       JUDGED — stats.sh's own stddev, squared, never a second
#       implementation. Prints the merged record with a `judge_rotation`
#       sub-object (never touches the `judge` key `judge`/`judge-batch` use).
#       Exit 0 — rotation enabled, variance computed, every configured
#       member reached JUDGED. Exit 4 — rotation enabled, variance computed,
#       but at least one configured member did not reach JUDGED (REFUSED,
#       UNAVAILABLE, or a malformed --judges entry's own row). Exit 1
#       CANNOT_EVALUATE — rotation mode disabled, a usage error, fewer than
#       2 configured judges or fewer than 2 configured provider families,
#       or (rotation ran but) the variance itself could not be computed
#       (too few JUDGED members, JUDGED members from only one provider
#       family, or a stats.sh failure).
#
# ── OPTIONAL CROSS-FAMILY JUDGE ROTATION (temperloop#1260) ─────────────────
# `judge-rotate` scores ONE record with SEVERAL judges (provider:model pairs
# spanning more than one provider family) and reports the VARIANCE of their
# quality_score across that panel. NEVER a second statistics implementation:
# the reported variance is stats.sh's OWN sample-stddev (`stats.sh verdict`'s
# `.stddev` field, computed by stats.py's `_sample_stdev`), squared here in a
# single line of jq arithmetic — nothing more is computed by this file.
#
# OFF BY DEFAULT (MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=0). With it off,
# `judge-rotate` CANNOT_EVALUATEs immediately, before touching the record or
# spawning anything, and `judge`/`judge-batch`'s own behaviour is
# byte-identical to the pre-rotation module: this file adds an entirely new
# subcommand plus two new settings; it does NOT modify cmd_judge,
# cmd_judge_batch, or _je_one_record's own logic in any way.
#
# EACH rotation member is scored via the EXACT SAME `_je_one_record` the
# single-judge path already uses above — the judge≠candidate guard, the
# non-default-provider allowlist+disclosure gate (pa_is_allowed/pa_disclose,
# the SAME committed allowlist and SAME disclosure log a candidate replay
# uses), and the candidate-session.sh spawn (containment overlay +
# provider-key health check) are therefore reused VERBATIM per rotated judge,
# never reimplemented for the panel case. A rotated judge outside the
# trusted default provider is refused (CANNOT_EVALUATE, no call made) unless
# it carries its own committed allowlist entry, exactly like a candidate
# replay; an allowed non-default judge's send appends to the SAME disclosure
# log a candidate replay appends to — never a parallel, rotation-only log.
#
# WHAT ROTATION REPORTS, AND WHAT IT DOES NOT PROVE. A low (or zero) variance
# across the rotated panel is evidence the judges AGREED — it is NOT evidence
# the shared judgment is free of model-family bias, because a bias every
# rotated family shares in common would never show up as variance at all. No
# emitted field, comment, or doc line anywhere in this section (or in
# `cmd_judge_rotate`'s own code) may claim rotation "proves" or "neutralizes"
# bias — the job here is to REPORT the disagreement this file can see, the
# same overclaim discipline the judge≠candidate guard's own header above
# applies to itself.
#
# FAIL-CLOSED (temperloop#1365 class, same as the rest of this file): an
# unreachable rotated judge, an unresolved allowlist for one, or a variance
# that cannot be computed (too few JUDGED members, or JUDGED members from
# only one provider family, or a stats.sh failure) is a distinct
# CANNOT_EVALUATE with a named reason and a non-zero exit — never a silent
# pass, a fabricated variance figure, or a zero standing in for a score or a
# variance this file never actually obtained.
#
# Every tunable below is a registered setting (workflows/scripts/config/
# setting-registry.tsv), defaulted in workflows/scripts/build/build.config.sh
# — named symbolically, never re-valued in prose (§ Named-setting convention).
# The `:=` fallbacks here are this file's own non-vendoring-caller layer-6
# default, matching that registry exactly.
#
# Kept POSIX-bash-3.2-friendly (no mapfile, no associative arrays, no GNU-only
# flags) — macOS dev shell + Linux CI.

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"CANNOT_EVALUATE","error":"jq not found"}'; echo "judge.sh: CANNOT EVALUATE — jq not found" >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATE_SESSION_SH="$HERE/candidate-session.sh"
ALLOWLIST_LIB="$HERE/allowlist.sh"
EMIT_MODEL_USAGE_SH="$HERE/../emit-model-usage.sh"
DEFAULT_RUBRIC="$HERE/rubric.md"
# stats.sh (temperloop#1249) — the ONE numeric core `judge-rotate` below
# consumes for its per-judge variance figure. Never a second implementation:
# this file only squares stats.sh's own `.stddev` output (see cmd_judge_rotate).
STATS_SH="$HERE/stats.sh"

# The ADR 0026 seat ROLE NAME this module's judge-call attribution records
# carry — a record-vocabulary constant, not an operator-tunable setting (same
# non-registry-row shape as replay.sh's own REPLAY_CANDIDATE_SEAT).
JUDGE_SEAT="replay-judge"
# The ADR 0028 trusted default provider — byte-identical to replay.sh's own
# REPLAY_TRUSTED_DEFAULT_PROVIDER / candidate-session.sh's _CS_DEFAULT_PROVIDER
# / validate-provider-disclosure.sh's TRUSTED_DEFAULT_PROVIDER; a vocabulary
# constant, not a setting (ADR 0028 forbids an operator-repointable exemption).
JUDGE_TRUSTED_DEFAULT_PROVIDER="anthropic"
# The ADR 0026 seat ROLE NAME `judge-rotate`'s per-member attribution records
# carry — distinct from JUDGE_SEAT above so a rotation call is distinguishable
# in the usage lake from a single-judge call, same non-registry-row
# vocabulary-constant shape.
JUDGE_ROTATION_SEAT="replay-judge-rotation"

# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
# The judge model — a STRONG-tier judge (the item's own framing), following
# the RETRO_JUDGE_MODEL naming convention within this module's own
# MODEL_COMPARISON_* namespace. Distinct from RETRO_JUDGE_MODEL (a different
# judge, a different job: unified-retrospection's epic-close judge, not a
# replay-quality judge) and from PIPELINE_DRIVE_MERGE_MODEL (same tier, a
# different call site).
: "${MODEL_COMPARISON_JUDGE_MODEL:=claude-opus-4-8}"
# Wall-clock bound on ONE judge model call, mirroring replay.sh's own
# REPLAY_CANDIDATE_TIMEOUT_SECS bound on one candidate call.
: "${MODEL_COMPARISON_JUDGE_TIMEOUT_SECS:=1800}"
# Optional cross-family judge rotation (temperloop#1260) — the config-named
# ROTATION MODE gate `judge-rotate` checks before doing anything else. OFF by
# default: with it 0 (or anything but "1"), `judge-rotate` refuses immediately
# and `judge`/`judge-batch`'s own behaviour is untouched (rotation lives
# entirely in its own subcommand, never a branch inside cmd_judge/cmd_judge_batch).
: "${MODEL_COMPARISON_JUDGE_ROTATION_ENABLED:=0}"
# The minimum number of rotation members that must reach JUDGED (scored)
# before a per-judge variance figure is reported at all. Passed to stats.sh
# as THIS invocation's own `--min-sample` (never the module-wide
# MODEL_COMPARISON_MIN_SAMPLE_N, which is sized for cost-delta outcome
# counts in the tens, not a judge panel) — see cmd_judge_rotate.
: "${MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES:=2}"

# shellcheck source=../lib/portable-timeout.sh
[ -f "$HERE/../lib/portable-timeout.sh" ] && . "$HERE/../lib/portable-timeout.sh"
if ! command -v run_with_timeout >/dev/null 2>&1; then
  # Defensive only — portable-timeout.sh ships alongside this file in every
  # kernel install; this degrades to an unbounded call rather than aborting.
  run_with_timeout() { shift; "$@"; }
fi

# shellcheck source=../lib/cannot-evaluate.sh
[ -f "$HERE/../lib/cannot-evaluate.sh" ] && . "$HERE/../lib/cannot-evaluate.sh"
if ! command -v cannot_evaluate_emit >/dev/null 2>&1; then
  # DEGRADED, never silently duplicated (temperloop#1475 review MEDIUM-3):
  # cannot-evaluate.sh ships alongside this file in every kernel install, so
  # reaching this branch means the checkout is structurally off — e.g. this
  # file reached via a symlink ($HERE resolves the DIRECTORY via `cd -P`,
  # which does not resolve a symlinked *file*, so a symlinked entry point
  # can land here even with a normal lib/ present) — or the lib is genuinely
  # missing. Re-typing the frozen contract's human-line shape here a second
  # time would be exactly the silent duplication this hoist exists to
  # eliminate, so this fallback does NOT pretend to be the real thing: it
  # defines RC_CANNOT_EVALUATE itself (so a caller using the lib's own
  # advertised idiom never hits an unbound-variable abort under `set -u`),
  # still emits the machine JSON so a downstream `.outcome` reader sees
  # CANNOT_EVALUATE, still fails CLOSED on that reserved code, but replaces
  # the human line with an explicit degradation notice naming what's wrong.
  RC_CANNOT_EVALUATE=2
  cannot_evaluate_emit() {
    jq -cn --arg e "$2" '{outcome:"CANNOT_EVALUATE",error:$e}'
    printf '%s: CANNOT-EVALUATE-DEGRADED — workflows/scripts/lib/cannot-evaluate.sh could not be sourced (checkout is structurally off); original message: %s\n' "$1" "$2" >&2
    return "$RC_CANNOT_EVALUATE"
  }
fi

usage() {
  cat <<'EOF' >&2
usage: judge.sh judge --record <file> [--rubric <path>] (--judge-runner <cmd> | --live)
                       [--model <id>] [--provider <name>] [--out <file>]
                       [--prompt-out <file>] [--repo <owner/repo>]
       judge.sh judge-batch --records-file <jsonl> [--rubric <path>] (--judge-runner <cmd> | --live)
                       [--model <id>] [--provider <name>] [--out <file>] [--repo <owner/repo>]
       judge.sh judge-rotate --record <file> --judges <provider:model,provider:model,...> \
                       [--rubric <path>] (--judge-runner <cmd> | --live) [--out <file>] [--repo <owner/repo>]
                       (optional, off by default — MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 to enable)
EOF
}

need_operand() {  # <flag> <remaining-arg-count> [<next-arg>]
  [ "$2" -ge 2 ] || { printf 'judge.sh: %s requires a value\n' "$1" >&2; return 2; }
  case "${3:-}" in
    --*) printf 'judge.sh: %s requires a value, got flag-like %s\n' "$1" "$3" >&2; return 2 ;;
    *) return 0 ;;
  esac
}

# ── fail-closed emission — delegates to the shared idiom in
#    workflows/scripts/lib/cannot-evaluate.sh (temperloop#1475): the machine
#    verdict on stdout, the distinct human line on stderr, and now
#    RC_CANNOT_EVALUATE (2) as ITS OWN return status — a caller that forgets
#    to branch on it fails closed rather than falling through. Every
#    existing caller already follows it with an explicit `return 1`, so this
#    changes no observed behavior.
_je_cannot_evaluate() {
  cannot_evaluate_emit "judge.sh" "$1"
}

_je_epoch_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null && return 0
  fi
  printf '%d' "$(( $(date +%s) * 1000 ))"
}

_je_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_je_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

# _je_outcome_ref <record-json> — the emit-model-usage.sh --outcome-ref shape
# validate-model-usage-emit.sh actually enforces: '(issue|pr):<ref>', no
# third prefix. Byte-identical convention to replay.sh execute's own
# item_ref construction (strip a leading '#', prefer issue over pr) — a
# THIRD ref-shape invented here ("judge:...") would fail that validator, as
# a smoke-tested local run of this file once did.
_je_outcome_ref() {
  local rec="$1" issue pr
  issue="$(jq -r '.issue // empty' <<<"$rec" 2>/dev/null)"
  pr="$(jq -r '.pr // empty' <<<"$rec" 2>/dev/null)"
  if [ -n "$issue" ]; then printf 'issue:%s\n' "${issue#\#}"
  elif [ -n "$pr" ]; then printf 'pr:%s\n' "$pr"
  else printf 'issue:unknown\n'; fi
}

# ── the guard, documented at its own site (see header) — prevents an EXACT
#    judge==candidate match; nothing broader. ─────────────────────────────
# _je_guard_blocks <judge_provider> <judge_model> <cand_provider> <cand_model>
# -> 0 (refuse) if identical, 1 (proceed) otherwise.
_je_guard_blocks() {
  [ "$1" = "$3" ] && [ "$2" = "$4" ]
}

# ── prompt construction — rubric.md flows in as PROMPT CONTENT ONLY, via a
#    plain cat; see the file header for what this is (and is not). ────────
_je_build_prompt() {  # <record-file> <rubric-file> <prompt-file>
  local record_file="$1" rubric_file="$2" prompt_file="$3"
  {
    printf 'You are the independent replay-record QUALITY JUDGE described in the rubric below. Read it in full before responding.\n\n'
    printf '## Rubric\n\n'
    cat "$rubric_file"
    printf '\n\n## Record to judge\n\n'
    printf -- '- item: %s\n' "$(jq -r '.issue // .pr // "unknown"' "$record_file")"
    printf -- '- title: %s\n' "$(jq -r '.title // ""' "$record_file")"
    printf -- '- scope: %s\n' "$(jq -r '.scope // ""' "$record_file")"
    printf -- '- candidate provider/model: %s / %s\n' \
      "$(jq -r '.candidate.provider // "unknown"' "$record_file")" \
      "$(jq -r '.candidate.model // "unknown"' "$record_file")"
    printf -- '- mechanical verdict: %s\n\n' "$(jq -r '.score.verdict // "unknown"' "$record_file")"
    printf '## Acceptance criteria\n'
    jq -r '(.acceptance // [])[] | "  - " + .' "$record_file"
    printf '\n## Diff summary (score.diff)\n'
    jq -c '.score.diff // {}' "$record_file"
    printf '\n## Gate result (score.gate_result)\n'
    jq -c '.score.gate_result // {}' "$record_file"
    printf '\n'
  } >"$prompt_file"
}

# ── response parsing — the model's text must be EXACTLY the contracted JSON
#    object; a markdown-fenced reply is tolerated (stripped), anything else
#    is a distinct "response-unparseable" degradation, never a fabricated
#    score. ──────────────────────────────────────────────────────────────
_je_extract_json_response() {  # <raw-text> -> prints the parsed object, or nothing
  local raw="$1" stripped
  if printf '%s' "$raw" | jq -e 'type=="object"' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c .
    return 0
  fi
  # Tolerate a ```json ... ``` or ``` ... ``` fence around an otherwise-valid
  # object — a documented real-world wrapping failure mode at the cheap tier
  # (see build.config.sh's CONFIGURE_AI_MODEL comment for the same class).
  stripped="$(printf '%s\n' "$raw" | sed -e '/^```/d')"
  if printf '%s' "$stripped" | jq -e 'type=="object"' >/dev/null 2>&1; then
    printf '%s' "$stripped" | jq -c .
    return 0
  fi
  return 1
}

_je_response_schema_ok() {  # <json-object> -> 0 if it matches the output contract
  jq -e '
    type=="object"
    and has("quality_score") and ((.quality_score|type)=="number") and (.quality_score>=0) and (.quality_score<=100)
    and has("dimensions") and (.dimensions|type=="object")
  ' >/dev/null 2>&1
}

# ── the ONE per-record judging function. Prints exactly one compact JSON
#    line to stdout. Returns 0 JUDGED / 1 CANNOT_EVALUATE / 2 REFUSED /
#    4 UNAVAILABLE — the exit-code table in the header, applied per record.
# _je_one_record <record-file> <rubric-file> <judge-provider> <judge-model>
#                <runner> <live-flag> <prompt-out-or-empty> <owner-repo-or-empty>
_je_one_record() {
  local record_file="$1" rubric_file="$2" judge_provider="$3" judge_model="$4" \
        runner="$5" live="$6" prompt_out="$7" owner_repo="$8"

  if [ ! -f "$record_file" ] || [ ! -r "$record_file" ]; then
    _je_cannot_evaluate "record not found or not a readable regular file: $record_file"
    return 1
  fi
  if [ ! -s "$record_file" ]; then
    _je_cannot_evaluate "record file is empty: $record_file"
    return 1
  fi
  if ! jq -e 'type=="object"' "$record_file" >/dev/null 2>&1; then
    _je_cannot_evaluate "record is not a JSON object: $record_file"
    return 1
  fi

  local cand_provider cand_model
  cand_provider="$(jq -r '.candidate.provider // empty' "$record_file" 2>/dev/null)"
  cand_model="$(jq -r '.candidate.model // empty' "$record_file" 2>/dev/null)"
  if [ -z "$cand_model" ]; then
    _je_cannot_evaluate "record carries no .candidate.model — run replay.sh execute (or otherwise populate the candidate sub-object) before judging"
    return 1
  fi

  local item_ref rec_issue rec_pr
  rec_issue="$(jq -r '.issue // empty' "$record_file" 2>/dev/null)"
  rec_pr="$(jq -r '.pr // empty' "$record_file" 2>/dev/null)"
  if [ -n "$rec_issue" ]; then item_ref="issue:${rec_issue#\#}"
  elif [ -n "$rec_pr" ]; then item_ref="pr:$rec_pr"
  else item_ref="record:unknown"; fi

  # ── THE GUARD — checked BEFORE any spend, any disclosure, any spawn. ────
  if _je_guard_blocks "$judge_provider" "$judge_model" "$cand_provider" "$cand_model"; then
    jq -cn --arg jp "$judge_provider" --arg jm "$judge_model" \
      --arg cp "$cand_provider" --arg cm "$cand_model" --arg ref "$item_ref" \
      '{outcome:"REFUSED", reason:"judge-equals-candidate",
        judge_provider:$jp, judge_model:$jm,
        candidate_provider:$cp, candidate_model:$cm, item_ref:$ref,
        guard:{enforced:true,
               scope:"prevents self-grading only (judge provider+model == candidate provider+model); does NOT neutralize model-family style bias — see rubric.md and this script'"'"'s own header"}}'
    printf 'judge.sh: REFUSED — judge (%s/%s) is identical to the candidate (%s/%s) for %s; a model may not grade itself\n' \
      "$judge_provider" "$judge_model" "$cand_provider" "$cand_model" "$item_ref" >&2
    return 2
  fi

  if [ ! -f "$rubric_file" ] || [ ! -r "$rubric_file" ]; then
    _je_cannot_evaluate "rubric file not found or not a readable regular file: $rubric_file"
    return 1
  fi

  # ── candidate-session.sh: same two structural guarantees a live candidate
  #    replay gets (containment overlay + provider-key health check),
  #    reused verbatim — never a second implementation. ───────────────────
  if [ ! -f "$CANDIDATE_SESSION_SH" ]; then
    _je_cannot_evaluate "candidate-session.sh not found at $CANDIDATE_SESSION_SH — the judge spawn seam is unavailable"
    return 1
  fi
  local cs_out cs_rc=0
  cs_out="$(bash "$CANDIDATE_SESSION_SH" resolve "Read" 2>&1)" || cs_rc=$?
  if [ "$cs_rc" -ne 0 ]; then
    _je_cannot_evaluate "candidate-session.sh reports its containment overlay is unusable (exit $cs_rc — 3=absent, 4=unreadable, 5=malformed): $cs_out"
    return 1
  fi
  local pf_out pf_rc=0
  pf_out="$(bash "$CANDIDATE_SESSION_SH" preflight --provider "$judge_provider" 2>&1)" || pf_rc=$?
  if [ "$pf_rc" -ne 0 ]; then
    _je_cannot_evaluate "candidate-session.sh preflight refused judge provider '$judge_provider': $pf_out"
    return 1
  fi

  # ── disclose before sending (ADR 0028 pairing) — same ordering guarantee
  #    replay.sh execute enforces: a failed disclosure refuses the send. ──
  local disclosed=false
  if [ "$judge_provider" != "$JUDGE_TRUSTED_DEFAULT_PROVIDER" ]; then
    if [ ! -f "$ALLOWLIST_LIB" ]; then
      _je_cannot_evaluate "allowlist.sh not found at $ALLOWLIST_LIB — cannot disclose a non-default-provider judge send, so refusing to make one"
      return 1
    fi
    # shellcheck source=./allowlist.sh
    . "$ALLOWLIST_LIB"
    if ! pa_disclose "$judge_provider" "$item_ref"; then
      _je_cannot_evaluate "pa_disclose refused to record a judge send to non-default provider '$judge_provider' for $item_ref — refusing to send undisclosed"
      return 1
    fi
    disclosed=true
  fi

  local scratch_dir prompt_file envelope_file
  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/judge-exec.XXXXXX")" || {
    _je_cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  prompt_file="$scratch_dir/prompt.txt"
  envelope_file="$scratch_dir/envelope.json"

  _je_build_prompt "$record_file" "$rubric_file" "$prompt_file"
  [ -n "$prompt_out" ] && cp "$prompt_file" "$prompt_out" 2>/dev/null || true

  local prompt_sha; prompt_sha="$(_je_sha256 <"$prompt_file")"

  # _je_unavailable <notice> — emits the record with the degradation marker
  # and cleans up. The ONE path for "the call could have happened but did
  # not produce a score" — never a fabricated or zero score standing in.
  _je_unavailable() {
    local notice="$1" dur="${2:-0}"
    jq -c --argjson j "$(jq -cn --arg jp "$judge_provider" --arg jm "$judge_model" \
        --arg cp "$cand_provider" --arg cm "$cand_model" --arg notice "$notice" \
        --argjson dur "$dur" --argjson disclosed "$disclosed" --arg prompt "$prompt_sha" \
        --arg ts "$(_je_now_iso)" \
        '{outcome:"UNAVAILABLE", scored:false, quality_score:null, dimensions:null,
          rationale:null, concerns:[],
          judge_provider:$jp, judge_model:$jm,
          degradation_notice:$notice,
          tokens:null, duration_ms:$dur, disclosed:$disclosed, prompt_sha256:$prompt,
          guard:{enforced:true, candidate_provider:$cp, candidate_model:$cm,
                 scope:"prevents self-grading only; does NOT neutralize model-family style bias"},
          evaluated_at:$ts}')" \
      '. + {judge:$j}' "$record_file"
    printf 'judge.sh: judge UNAVAILABLE for %s — %s\n' "$item_ref" "$notice" >&2
    rm -rf "$scratch_dir"
    return 4
  }

  local started ended run_rc=0 measured_ms
  started="$(_je_epoch_ms)"
  if [ "$live" -eq 1 ]; then
    local -a claude_args=(-p --output-format json)
    [ -n "$judge_model" ] && claude_args+=(--model "$judge_model")
    run_with_timeout "$MODEL_COMPARISON_JUDGE_TIMEOUT_SECS" \
      bash "$CANDIDATE_SESSION_SH" spawn --provider "$judge_provider" -- "${claude_args[@]}" \
      <"$prompt_file" >"$envelope_file" 2>"$scratch_dir/stderr.txt" || run_rc=$?
  else
    # Deliberately unquoted: a runner is a command STRING, split on
    # whitespace, exactly like replay.sh execute's --candidate-runner.
    # shellcheck disable=SC2086
    run_with_timeout "$MODEL_COMPARISON_JUDGE_TIMEOUT_SECS" \
      $runner "$prompt_file" >"$envelope_file" 2>"$scratch_dir/stderr.txt" || run_rc=$?
  fi
  ended="$(_je_epoch_ms)"
  measured_ms=$(( ended - started ))
  [ "$measured_ms" -lt 0 ] && measured_ms=0

  if [ "$run_rc" -eq 137 ]; then
    _je_unavailable "judge-timeout: the judge call exceeded MODEL_COMPARISON_JUDGE_TIMEOUT_SECS (${MODEL_COMPARISON_JUDGE_TIMEOUT_SECS}s)" "$measured_ms"; return $?
  fi
  if [ "$run_rc" -ne 0 ]; then
    _je_unavailable "judge-spawn: the judge runner exited $run_rc: $(head -c 400 "$scratch_dir/stderr.txt" 2>/dev/null)" "$measured_ms"; return $?
  fi
  if ! jq -e 'type=="object"' "$envelope_file" >/dev/null 2>&1; then
    _je_unavailable "envelope-parse: the judge runner's stdout is not a JSON object: $(head -c 400 "$envelope_file" 2>/dev/null)" "$measured_ms"; return $?
  fi
  if [ "$(jq -r '.is_error // false' "$envelope_file")" = "true" ]; then
    _je_unavailable "vendor-error: the envelope reports is_error=true: $(jq -r '.subtype // .error // "no detail"' "$envelope_file")" "$measured_ms"; return $?
  fi

  local tokens_json
  tokens_json="$(jq -c '
    (.modelUsage // {}) | to_entries
    | map(select((.value|type=="object")))
    | if length == 0 then null else
        {input:(map(.value.inputTokens // 0)|add),
         output:(map(.value.outputTokens // 0)|add),
         cache_read:(map(.value.cacheReadInputTokens // 0)|add),
         cache_creation:(map(.value.cacheCreationInputTokens // 0)|add)}
      end' "$envelope_file" 2>/dev/null)"
  if [ -z "$tokens_json" ] || [ "$tokens_json" = "null" ]; then
    _je_unavailable "envelope-usage-missing: the envelope carries no usable modelUsage block, so no token count exists for this judge call" "$measured_ms"; return $?
  fi

  local resolved_model
  resolved_model="$(jq -r '
    (.modelUsage // {}) | to_entries
    | map(select((.value|type=="object")))
    | sort_by( ((.value.inputTokens // 0) + (.value.outputTokens // 0)
              + (.value.cacheReadInputTokens // 0) + (.value.cacheCreationInputTokens // 0)) )
    | if length == 0 then "" else (last | .key) end' "$envelope_file" 2>/dev/null)"
  [ -n "$resolved_model" ] || resolved_model="$judge_model"

  local env_duration duration_ms
  env_duration="$(jq -r '.duration_ms // empty' "$envelope_file" 2>/dev/null)"
  case "$env_duration" in ''|*[!0-9]*) duration_ms="$measured_ms" ;; *) duration_ms="$env_duration" ;; esac

  local resp_text parsed
  resp_text="$(jq -r '.result // .raw // empty' "$envelope_file" 2>/dev/null)"
  if [ -z "$resp_text" ]; then
    _je_unavailable "response-empty: the envelope's .result/.raw carried no text to judge from" "$duration_ms"; return $?
  fi
  if ! parsed="$(_je_extract_json_response "$resp_text")"; then
    _je_unavailable "response-unparseable: the judge's reply was not the contracted JSON object (nor a markdown-fenced one): $(printf '%s' "$resp_text" | head -c 300)" "$duration_ms"; return $?
  fi
  if ! _je_response_schema_ok <<<"$parsed"; then
    _je_unavailable "response-schema-invalid: the judge's reply parsed as JSON but did not carry a numeric quality_score (0-100) and a dimensions object: $parsed" "$duration_ms"; return $?
  fi

  local quality_score dimensions rationale concerns judge_obj
  quality_score="$(jq -c '.quality_score' <<<"$parsed")"
  dimensions="$(jq -c '.dimensions' <<<"$parsed")"
  rationale="$(jq -r '.rationale // ""' <<<"$parsed")"
  concerns="$(jq -c '.concerns // []' <<<"$parsed")"

  judge_obj="$(jq -cn \
    --arg jp "$judge_provider" --arg jm "$resolved_model" \
    --argjson qs "$quality_score" --argjson dims "$dimensions" \
    --arg rationale "$rationale" --argjson concerns "$concerns" \
    --argjson tokens "$tokens_json" --argjson dur "$duration_ms" \
    --argjson disclosed "$disclosed" --arg prompt "$prompt_sha" \
    --arg cp "$cand_provider" --arg cm "$cand_model" --arg ts "$(_je_now_iso)" \
    '{outcome:"JUDGED", scored:true,
      judge_provider:$jp, judge_model:$jm,
      quality_score:$qs, dimensions:$dims,
      rationale:$rationale, concerns:$concerns,
      tokens:$tokens, duration_ms:$dur, disclosed:$disclosed, prompt_sha256:$prompt,
      guard:{enforced:true, candidate_provider:$cp, candidate_model:$cm,
             scope:"prevents self-grading only; does NOT neutralize model-family style bias"},
      evaluated_at:$ts}')"

  jq -c --argjson j "$judge_obj" '. + {judge:$j}' "$record_file"

  rm -rf "$scratch_dir"
  return 0
}

# ── record preservation for judge-batch (temperloop#1556) ────────────────
# See this file's header § THE BATCH OUTPUT IS THE INPUT, ANNOTATED. These
# three helpers exist ONLY for the batch row loop; `judge` (single record)
# still prints `_je_one_record`'s bare verdict on stdout, which is its
# documented one-record contract and loses nothing (the caller still holds
# the record it passed in).

# _je_unjudgeable_by_construction <record-file> — true for a row that was
# never judgeable in the first place, as opposed to one the judge failed on.
# The signature is replay.sh's own integration-error record: the candidate
# spawn failed before it produced a diff, so `.candidate.outcome` is
# "integration-error" and (the spawn having failed before a model resolved)
# `.candidate.model` is absent. Both halves are required — a record that
# carries a model is one the judge CAN be pointed at, and silently skipping
# it here would be a fabricated non-judgment rather than a structural one.
_je_unjudgeable_by_construction() {
  jq -e '
    type=="object"
    and ((.candidate | type) == "object")
    and (.candidate.outcome == "integration-error")
    and ((.candidate.model // null) == null)
  ' "$1" >/dev/null 2>&1
}

# _je_unjudged_marker <reason> <detail> — the top-level `unjudged` marker an
# unjudgeable-by-construction row carries. Deliberately NOT a `judge`
# sub-object: a record with no `judge.outcome` is counted as unjudged by the
# comparison report, which is the honest bucket for a row no judge ever saw.
_je_unjudged_marker() {
  jq -cn --arg r "$1" --arg d "$2" --arg ts "$(_je_now_iso)" \
    '{unjudged:true, reason:$r, detail:$d, judged:false, recorded_at:$ts}'
}

# _je_judgment_absent <outcome> <notice> <bare-verdict-json> — the `judge`
# sub-object a row the judge genuinely could not complete carries. Same
# shape as _je_unavailable's, so a consumer reads one vocabulary for every
# non-JUDGED outcome: scored:false, quality_score:null, and a NAMED
# degradation_notice — never a fabricated or zero score standing in.
_je_judgment_absent() {
  local outcome="$1" notice="$2" detail="${3:-}"
  if ! printf '%s' "$detail" | jq -e 'type=="object"' >/dev/null 2>&1; then detail='null'; fi
  jq -cn --arg o "$outcome" --arg n "$notice" --argjson d "$detail" --arg ts "$(_je_now_iso)" \
    '{outcome:$o, scored:false, quality_score:null, dimensions:null,
      rationale:null, concerns:[], degradation_notice:$n, verdict:$d,
      evaluated_at:$ts}'
}

# ── judge (single record) ────────────────────────────────────────────────
cmd_judge() {
  local record="" rubric="$DEFAULT_RUBRIC" provider="$JUDGE_TRUSTED_DEFAULT_PROVIDER" \
        model="$MODEL_COMPARISON_JUDGE_MODEL" runner="" live=0 out="" prompt_out="" owner_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) need_operand --record "$#" "${2:-}" || return 2; record="$2"; shift 2 ;;
      --rubric) need_operand --rubric "$#" "${2:-}" || return 2; rubric="$2"; shift 2 ;;
      --provider) need_operand --provider "$#" "${2:-}" || return 2; provider="$2"; shift 2 ;;
      --model) need_operand --model "$#" "${2:-}" || return 2; model="$2"; shift 2 ;;
      --repo) need_operand --repo "$#" "${2:-}" || return 2; owner_repo="$2"; shift 2 ;;
      --judge-runner) need_operand --judge-runner "$#" "${2:-}" || return 2; runner="$2"; shift 2 ;;
      --out) need_operand --out "$#" "${2:-}" || return 2; out="$2"; shift 2 ;;
      --prompt-out) need_operand --prompt-out "$#" "${2:-}" || return 2; prompt_out="$2"; shift 2 ;;
      --live) live=1; shift ;;
      *) printf 'judge.sh judge: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$record" ] || { _je_cannot_evaluate "no --record given"; return 1; }
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    _je_cannot_evaluate "--judge-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if [ -z "$runner" ] && [ "$live" -eq 0 ]; then
    _je_cannot_evaluate "no judge runner configured: pass --judge-runner <cmd> (a recorded/stubbed runner) or the explicit --live flag. There is deliberately NO implicit fallback to a 'claude' binary on PATH — an unset seam refuses rather than silently spending"
    return 1
  fi

  local result rc=0
  result="$(_je_one_record "$record" "$rubric" "$provider" "$model" "$runner" "$live" "$prompt_out" "$owner_repo")" || rc=$?
  printf '%s\n' "$result"
  if [ -n "$out" ] && [ "$rc" -ne 1 ]; then printf '%s\n' "$result" >"$out"; fi

  # Attribution: only for a call that actually happened (JUDGED or
  # UNAVAILABLE both spent an attempt; REFUSED/CANNOT_EVALUATE never spawned).
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then
    if [ -x "$EMIT_MODEL_USAGE_SH" ]; then
      local outcome_ref; outcome_ref="$(_je_outcome_ref "$result")"
      local dur; dur="$(jq -r '.judge.duration_ms // 0' <<<"$result" 2>/dev/null)"
      local -a ea=(--seat "$JUDGE_SEAT" --model "$(jq -r '.judge.judge_model // "unknown"' <<<"$result")" \
                   --usage-source cli-envelope --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}")
      [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
      if [ "$rc" -eq 0 ]; then
        ea+=(--provider "$provider"
             --input-tokens "$(jq -r '.judge.tokens.input // 0' <<<"$result")"
             --output-tokens "$(jq -r '.judge.tokens.output // 0' <<<"$result")"
             --cache-read-tokens "$(jq -r '.judge.tokens.cache_read // 0' <<<"$result")"
             --cache-creation-tokens "$(jq -r '.judge.tokens.cache_creation // 0' <<<"$result")")
      else
        ea=(--seat "$JUDGE_SEAT" --model "${model:-unknown}" --usage-source unavailable \
            --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}")
        [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
      fi
      "$EMIT_MODEL_USAGE_SH" "${ea[@]}" >/dev/null 2>&1 || true
    fi
  fi

  return "$rc"
}

# ── judge-batch ───────────────────────────────────────────────────────────
cmd_judge_batch() {
  local records="" rubric="$DEFAULT_RUBRIC" provider="$JUDGE_TRUSTED_DEFAULT_PROVIDER" \
        model="$MODEL_COMPARISON_JUDGE_MODEL" runner="" live=0 out="" owner_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --records-file) need_operand --records-file "$#" "${2:-}" || return 2; records="$2"; shift 2 ;;
      --rubric) need_operand --rubric "$#" "${2:-}" || return 2; rubric="$2"; shift 2 ;;
      --provider) need_operand --provider "$#" "${2:-}" || return 2; provider="$2"; shift 2 ;;
      --model) need_operand --model "$#" "${2:-}" || return 2; model="$2"; shift 2 ;;
      --repo) need_operand --repo "$#" "${2:-}" || return 2; owner_repo="$2"; shift 2 ;;
      --judge-runner) need_operand --judge-runner "$#" "${2:-}" || return 2; runner="$2"; shift 2 ;;
      --out) need_operand --out "$#" "${2:-}" || return 2; out="$2"; shift 2 ;;
      --live) live=1; shift ;;
      *) printf 'judge.sh judge-batch: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$records" ] || { _je_cannot_evaluate "no --records-file given"; return 1; }
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    _je_cannot_evaluate "--judge-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if [ -z "$runner" ] && [ "$live" -eq 0 ]; then
    _je_cannot_evaluate "no judge runner configured: pass --judge-runner <cmd> (a recorded/stubbed runner) or the explicit --live flag. There is deliberately NO implicit fallback to a 'claude' binary on PATH — an unset seam refuses rather than silently spending"
    return 1
  fi
  if [ ! -f "$records" ] || [ ! -r "$records" ]; then
    _je_cannot_evaluate "records file not found or not a readable regular file: $records"
    return 1
  fi
  local n_lines
  n_lines="$(grep -c . "$records" 2>/dev/null || true)"
  case "$n_lines" in ''|*[!0-9]*) n_lines=0 ;; esac
  if [ "$n_lines" -eq 0 ]; then
    _je_cannot_evaluate "records file has no records: $records"
    return 1
  fi

  local batch_tmp; batch_tmp="$(mktemp -d "${TMPDIR:-/tmp}/judge-batch.XXXXXX")" || {
    _je_cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$batch_tmp'" RETURN

  local out_stream="$batch_tmp/out.jsonl"
  : >"$out_stream"

  local degraded=0 n_degraded=0 n_unjudgeable=0 line row_file row_out row_rc row_final
  row_file="$batch_tmp/row.json"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >"$row_file"

    # ── rule 2: unjudgeable BY CONSTRUCTION is not a failure. Checked
    #    BEFORE _je_one_record so no judge call is spent, no stderr
    #    degradation line is printed, and the row cannot land in the
    #    degraded tally (temperloop#1556 — see the file header).
    if _je_unjudgeable_by_construction "$row_file"; then
      row_final="$(jq -c --argjson u "$(_je_unjudged_marker "unjudgeable-by-construction" \
          "this is an integration-error record: the candidate spawn failed before it produced a diff or resolved a model, so there is nothing for a judge to score. It is passed through UNJUDGED — never replaced, and never counted as a judge failure — and the comparison report consumes it as a compatibility fact")" \
        '. + {unjudged:$u}' "$row_file" 2>/dev/null)"
      [ -n "$row_final" ] || row_final="$line"
      printf '%s\n' "$row_final" >>"$out_stream"
      n_unjudgeable=$((n_unjudgeable + 1))
      continue
    fi

    row_rc=0
    row_out="$(_je_one_record "$row_file" "$rubric" "$provider" "$model" "$runner" "$live" "" "$owner_repo")" || row_rc=$?

    # ── rule 1: no input record is ever dropped OR overwritten. rc 0/4 are
    #    already "the record, annotated" (_je_one_record merged the judge
    #    sub-object onto it); rc 1/2 return a BARE verdict object, which is
    #    attached to the original row rather than substituted for it.
    case "$row_rc" in
      0|4) row_final="$row_out" ;;
      *)
        local ja_outcome ja_notice ja_obj
        ja_outcome="$(jq -r '.outcome // "CANNOT_EVALUATE"' <<<"$row_out" 2>/dev/null)"
        [ -n "$ja_outcome" ] || ja_outcome="CANNOT_EVALUATE"
        if [ "$row_rc" -eq 2 ]; then
          ja_notice="judge-refused: $(jq -r '.reason // "the judge≠candidate guard refused this row"' <<<"$row_out" 2>/dev/null)"
        else
          ja_notice="judge-cannot-evaluate: $(jq -r '.error // "the judge could not evaluate this row"' <<<"$row_out" 2>/dev/null)"
        fi
        ja_obj="$(_je_judgment_absent "$ja_outcome" "$ja_notice" "$row_out")"
        row_final="$(jq -c --argjson j "$ja_obj" '. + {judge:$j}' "$row_file" 2>/dev/null)"
        if [ -z "$row_final" ]; then
          # The input LINE is not a JSON object, so it cannot carry a merged
          # field — preserve it verbatim inside the emitted envelope instead.
          row_final="$(jq -cn --argjson j "$ja_obj" \
            --arg raw "$line" '$j + {unjudged:true, original_line:$raw}' 2>/dev/null)"
        fi
        [ -n "$row_final" ] || row_final="$row_out"
        ;;
    esac
    printf '%s\n' "$row_final" >>"$out_stream"
    if [ "$row_rc" -ne 0 ]; then degraded=1; n_degraded=$((n_degraded + 1)); fi

    if [ "$row_rc" -eq 0 ] || [ "$row_rc" -eq 4 ]; then
      if [ -x "$EMIT_MODEL_USAGE_SH" ]; then
        local outcome_ref dur
        outcome_ref="$(_je_outcome_ref "$row_out")"
        dur="$(jq -r '.judge.duration_ms // 0' <<<"$row_out" 2>/dev/null)"
        local -a ea
        if [ "$row_rc" -eq 0 ]; then
          ea=(--seat "$JUDGE_SEAT" --model "$(jq -r '.judge.judge_model // "unknown"' <<<"$row_out")" \
              --provider "$provider" --usage-source cli-envelope --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}" \
              --input-tokens "$(jq -r '.judge.tokens.input // 0' <<<"$row_out")" \
              --output-tokens "$(jq -r '.judge.tokens.output // 0' <<<"$row_out")" \
              --cache-read-tokens "$(jq -r '.judge.tokens.cache_read // 0' <<<"$row_out")" \
              --cache-creation-tokens "$(jq -r '.judge.tokens.cache_creation // 0' <<<"$row_out")")
        else
          ea=(--seat "$JUDGE_SEAT" --model "${model:-unknown}" --usage-source unavailable \
              --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}")
        fi
        [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
        "$EMIT_MODEL_USAGE_SH" "${ea[@]}" >/dev/null 2>&1 || true
      fi
    fi
  done <"$records"

  cat "$out_stream"
  if [ -n "$out" ]; then cp "$out_stream" "$out" 2>/dev/null || true; fi

  if [ "$n_unjudgeable" -gt 0 ]; then
    printf 'judge.sh judge-batch: %s of %s rows were unjudgeable BY CONSTRUCTION (integration-error records with no candidate model) — each passed through UNJUDGED with its own marker, spent no judge call, and is NOT counted as a degradation\n' \
      "$n_unjudgeable" "$n_lines" >&2
  fi
  [ "$degraded" -eq 0 ] && return 0
  # The tally is the loop's OWN per-row count, never a grep over the output
  # stream: every emitted line is now the record itself, whose `.candidate
  # .outcome` text would false-positive such a scan (temperloop#1556).
  printf 'judge.sh judge-batch: %s of %s rows did not reach JUDGED — see the per-row degradation_notice/outcome fields above\n' \
    "$n_degraded" "$n_lines" >&2
  return 4
}

# ── judge-rotate (temperloop#1260, optional cross-family judge rotation) ────
# See this file's own header § OPTIONAL CROSS-FAMILY JUDGE ROTATION. OFF BY
# DEFAULT — the very first thing this function does past arg-parsing is check
# MODEL_COMPARISON_JUDGE_ROTATION_ENABLED and refuse if it isn't exactly "1".
cmd_judge_rotate() {
  local record="" rubric="$DEFAULT_RUBRIC" judges_spec="" runner="" live=0 out="" owner_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) need_operand --record "$#" "${2:-}" || return 2; record="$2"; shift 2 ;;
      --rubric) need_operand --rubric "$#" "${2:-}" || return 2; rubric="$2"; shift 2 ;;
      --judges) need_operand --judges "$#" "${2:-}" || return 2; judges_spec="$2"; shift 2 ;;
      --repo) need_operand --repo "$#" "${2:-}" || return 2; owner_repo="$2"; shift 2 ;;
      --judge-runner) need_operand --judge-runner "$#" "${2:-}" || return 2; runner="$2"; shift 2 ;;
      --out) need_operand --out "$#" "${2:-}" || return 2; out="$2"; shift 2 ;;
      --live) live=1; shift ;;
      *) printf 'judge.sh judge-rotate: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$record" ] || { _je_cannot_evaluate "no --record given"; return 1; }
  [ -n "$judges_spec" ] || { _je_cannot_evaluate "no --judges given — rotation mode requires a comma-separated 'provider:model,provider:model,...' list of two or more rotation members spanning more than one provider family"; return 1; }
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    _je_cannot_evaluate "--judge-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if [ -z "$runner" ] && [ "$live" -eq 0 ]; then
    _je_cannot_evaluate "no judge runner configured: pass --judge-runner <cmd> (a recorded/stubbed runner) or the explicit --live flag. There is deliberately NO implicit fallback to a 'claude' binary on PATH — an unset seam refuses rather than silently spending, and rotation multiplies judge calls so this leak matters even more here"
    return 1
  fi

  # ── the config-named rotation-mode gate — OFF by default ─────────────────
  if [ "$MODEL_COMPARISON_JUDGE_ROTATION_ENABLED" != "1" ]; then
    _je_cannot_evaluate "rotation mode is disabled (MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=$MODEL_COMPARISON_JUDGE_ROTATION_ENABLED) — set MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 to enable optional cross-family judge rotation (temperloop#1260). With it off (the default), judge-rotate refuses before touching the record or spawning anything, and judge/judge-batch's own behaviour is unaffected"
    return 1
  fi

  # ── parse --judges into provider/model pairs (house convention: IFS=','
  #    read -ra, same shape as validate-design-brief.sh / plan.sh) ──────────
  local -a jr_raw=() jr_providers=() jr_models=()
  IFS=',' read -ra jr_raw <<<"$judges_spec"
  local entry p m
  for entry in "${jr_raw[@]}"; do
    entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$entry" ] || continue
    case "$entry" in
      *:*) ;;
      *) _je_cannot_evaluate "malformed --judges entry '$entry' — expected 'provider:model'"; return 1 ;;
    esac
    p="${entry%%:*}"
    m="${entry#*:}"
    if [ -z "$p" ] || [ -z "$m" ]; then
      _je_cannot_evaluate "malformed --judges entry '$entry' — provider and model must both be non-empty"
      return 1
    fi
    jr_providers+=("$p")
    jr_models+=("$m")
  done

  local n_configured="${#jr_providers[@]}"
  if [ "$n_configured" -lt 2 ]; then
    _je_cannot_evaluate "rotation requires at least 2 configured judges, got $n_configured (--judges '$judges_spec')"
    return 1
  fi
  local n_configured_families
  n_configured_families="$(printf '%s\n' "${jr_providers[@]}" | sort -u | grep -c .)"
  if [ "$n_configured_families" -lt 2 ]; then
    _je_cannot_evaluate "rotation requires configured judges from more than one provider family (cross-vendor) — got $n_configured_families distinct provider(s) among: $(printf '%s ' "${jr_providers[@]}")"
    return 1
  fi

  # ── run EVERY configured judge through the exact same per-record function
  #    the single-judge path uses (guard, allowlist+disclosure, spawn — all
  #    reused verbatim, never a second implementation) ──────────────────────
  local -a jr_tagged=()
  local idx=0 one_out one_rc jp jm tagged
  while [ "$idx" -lt "$n_configured" ]; do
    jp="${jr_providers[$idx]}"
    jm="${jr_models[$idx]}"
    one_rc=0
    one_out="$(_je_one_record "$record" "$rubric" "$jp" "$jm" "$runner" "$live" "" "$owner_repo")" || one_rc=$?

    tagged="$(jq -c --arg jp "$jp" --arg jm "$jm" \
      'if has("judge") then {rotation_provider:$jp, rotation_model:$jm} + .judge
       else {rotation_provider:$jp, rotation_model:$jm} + . end' <<<"$one_out" 2>/dev/null)"
    if [ -z "$tagged" ]; then
      tagged="$(jq -cn --arg jp "$jp" --arg jm "$jm" \
        '{rotation_provider:$jp, rotation_model:$jm, outcome:"CANNOT_EVALUATE", error:"rotation member produced no parseable output"}')"
    fi
    jr_tagged+=("$tagged")

    # Attribution: only for a call that actually happened (JUDGED or
    # UNAVAILABLE both spent an attempt; REFUSED/CANNOT_EVALUATE never spawned).
    if [ "$one_rc" -eq 0 ] || [ "$one_rc" -eq 4 ]; then
      if [ -x "$EMIT_MODEL_USAGE_SH" ]; then
        local outcome_ref dur
        outcome_ref="$(_je_outcome_ref "$one_out")"
        dur="$(jq -r '.judge.duration_ms // 0' <<<"$one_out" 2>/dev/null)"
        local -a ea
        if [ "$one_rc" -eq 0 ]; then
          ea=(--seat "$JUDGE_ROTATION_SEAT" --model "$(jq -r '.judge.judge_model // "unknown"' <<<"$one_out")" \
              --provider "$jp" --usage-source cli-envelope --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}" \
              --input-tokens "$(jq -r '.judge.tokens.input // 0' <<<"$one_out")" \
              --output-tokens "$(jq -r '.judge.tokens.output // 0' <<<"$one_out")" \
              --cache-read-tokens "$(jq -r '.judge.tokens.cache_read // 0' <<<"$one_out")" \
              --cache-creation-tokens "$(jq -r '.judge.tokens.cache_creation // 0' <<<"$one_out")")
        else
          ea=(--seat "$JUDGE_ROTATION_SEAT" --model "${jm:-unknown}" --usage-source unavailable \
              --outcome-ref "$outcome_ref" --duration-ms "${dur:-0}")
        fi
        [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
        "$EMIT_MODEL_USAGE_SH" "${ea[@]}" >/dev/null 2>&1 || true
      fi
    fi
    idx=$((idx + 1))
  done

  local judges_json scores_json n_judged n_families_judged
  judges_json="$(printf '%s\n' "${jr_tagged[@]}" | jq -cs '.')"
  scores_json="$(jq -c '[.[] | select(.outcome=="JUDGED") | .quality_score]' <<<"$judges_json")"
  n_judged="$(jq 'length' <<<"$scores_json")"
  n_families_judged="$(jq '[.[] | select(.outcome=="JUDGED") | .rotation_provider] | unique | length' <<<"$judges_json")"

  # ── variance — stats.sh's OWN sample-stddev, squared here; never a second
  #    statistics implementation (see this file's header). --min-sample is
  #    passed as n_judged itself so THIS command's own MODEL_COMPARISON_
  #    JUDGE_ROTATION_MIN_JUDGES floor governs, not the module-wide
  #    MODEL_COMPARISON_MIN_SAMPLE_N (sized for cost-delta outcome counts,
  #    not a judge panel). ─────────────────────────────────────────────────
  local variance_obj="null" variance_reason=""
  if [ "$n_judged" -lt "$MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES" ]; then
    variance_reason="insufficient JUDGED rotation members: got $n_judged, need >= $MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES (MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES) — variance cannot be computed"
  elif [ "$n_families_judged" -lt 2 ]; then
    variance_reason="rotation requires JUDGED scores from more than one provider family; only $n_families_judged distinct provider(s) among the JUDGED members — variance cannot be computed"
  else
    local stats_out stats_rc=0
    stats_out="$(bash "$STATS_SH" verdict --deltas "$scores_json" --min-sample "$n_judged" 2>&1)" || stats_rc=$?
    if [ "$stats_rc" -ne 0 ]; then
      variance_reason="stats.sh verdict failed (rc=$stats_rc) while computing the rotation variance: $(printf '%s' "$stats_out" | head -c 300)"
    elif ! jq -e 'has("stddev")' >/dev/null 2>&1 <<<"$stats_out"; then
      variance_reason="stats.sh verdict returned no stddev for the rotation scores (unexpected shape): $(printf '%s' "$stats_out" | head -c 300)"
    else
      local sd degenerate_flag
      sd="$(jq -r '.stddev' <<<"$stats_out")"
      degenerate_flag="$(jq -r '.degenerate // false' <<<"$stats_out")"
      # squaring stats.sh's own stddev — the ONE arithmetic step this file
      # performs; the dispersion computation itself lives entirely in
      # stats.py's _sample_stdev, never reimplemented here.
      variance_obj="$(jq -cn --argjson sd "$sd" --argjson n "$n_judged" --argjson deg "$degenerate_flag" \
        '{value: ($sd * $sd), stddev: $sd, n_judged: $n, degenerate: $deg, computed_by: "stats.sh verdict (.stddev, squared here — no second implementation)"}')"
    fi
  fi

  local overall_outcome all_judged=1 exit_rc
  if [ "$variance_obj" = "null" ]; then
    overall_outcome="CANNOT_EVALUATE"
  else
    overall_outcome="ROTATED"
  fi
  if jq -e 'any(.[]; .outcome != "JUDGED")' <<<"$judges_json" >/dev/null 2>&1; then
    all_judged=0
  fi
  if [ "$overall_outcome" = "CANNOT_EVALUATE" ]; then
    exit_rc=1
  elif [ "$all_judged" -eq 1 ]; then
    exit_rc=0
  else
    exit_rc=4
  fi

  # ── the overclaim discipline, stated in the emitted record itself, not
  #    only in this file's comments (see § OPTIONAL CROSS-FAMILY JUDGE
  #    ROTATION above) ───────────────────────────────────────────────────
  local disclaimer="Judge rotation REPORTS the spread (variance) in quality_score across judges from different provider families scoring the SAME record — it does NOT PROVE the resulting judgment is free of model-family bias. Low or zero variance across the rotated panel is evidence the judges AGREED, not evidence the judgment is unbiased: a bias every rotated family shares in common would not show up as variance at all."

  local judge_rotation_obj
  judge_rotation_obj="$(jq -cn \
    --arg outcome "$overall_outcome" \
    --argjson n_configured "$n_configured" \
    --argjson n_configured_families "$n_configured_families" \
    --argjson n_judged "$n_judged" \
    --argjson n_families_judged "$n_families_judged" \
    --argjson judges "$judges_json" \
    --argjson variance "$variance_obj" \
    --arg variance_reason "$variance_reason" \
    --arg disclaimer "$disclaimer" \
    --arg ts "$(_je_now_iso)" \
    '{outcome:$outcome, rotation_enabled:true,
      n_configured:$n_configured, n_configured_families:$n_configured_families,
      n_judged:$n_judged, n_families_judged:$n_families_judged,
      judges:$judges, variance:$variance,
      variance_unavailable_reason: (if $variance == null then $variance_reason else null end),
      disclaimer:$disclaimer, evaluated_at:$ts}')"

  local final_out
  if [ -f "$record" ] && [ -r "$record" ] && [ -s "$record" ] && jq -e 'type=="object"' "$record" >/dev/null 2>&1; then
    final_out="$(jq -c --argjson jr "$judge_rotation_obj" '. + {judge_rotation:$jr}' "$record")"
  else
    final_out="$judge_rotation_obj"
  fi
  printf '%s\n' "$final_out"
  if [ -n "$out" ]; then printf '%s\n' "$final_out" >"$out" 2>/dev/null || true; fi

  return "$exit_rc"
}

# ── dispatch ──────────────────────────────────────────────────────────────
[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  judge)        cmd_judge "$@" ;;
  judge-batch)  cmd_judge_batch "$@" ;;
  judge-rotate) cmd_judge_rotate "$@" ;;
  -h|--help)    usage; exit 0 ;;
  *)            usage; exit 2 ;;
esac
