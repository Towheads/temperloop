#!/usr/bin/env bash
#
# macos-gate-timing-report.sh — recompute every table in
# docs/validation/macos-ci-gate-timing.md from the RECORDED datasets beside
# it, so none of that document's numbers has to be taken on trust
# (temperloop#968, measurement phase).
#
# ZERO NETWORK, ZERO `gh`, deterministic. It reads only
# docs/validation/data/macos-ci-gate-timing/*.tsv — the per-gate wall-clock
# tables `nightly-macos.yml` already publishes on both of its legs
# (QUALITY_GATES_STEP_SUMMARY=1, see docs/features/quality-gates.md), captured
# once and committed. This is deliberately NOT a gate and is wired into no CI
# workflow: it is an opt-in, hand-run reproduction of a point-in-time
# measurement, the same shape as `make validate-clean-host-ks-search`.
#
# WHY THE DATA IS COMMITTED RATHER THAN FETCHED. GitHub expires Actions logs,
# so a script that re-derived these numbers live would answer differently (or
# not at all) a few months from now, and the follow-up work that has to decide
# a reintroduction target needs the baseline it was decided against to still be
# readable. Recorded fixtures over live network is also this repo's own
# engineering principle 3.
#
# HOW THE DATASETS WERE CAPTURED (repeat this to add a night):
#
#   gh api repos/Towheads/temperloop/actions/runs/<RUN_ID>/jobs \
#     --jq '.jobs[] | "\(.id) \(.name)"'
#   gh run view <RUN_ID> --repo Towheads/temperloop --job <JOB_ID> --log \
#     | grep -oE '\[(ok|FAIL)\][[:space:]]*\([[:space:]]*[0-9]+s\)[[:space:]].*' \
#     | sed -E 's/^\[(ok|FAIL)\][[:space:]]*\([[:space:]]*([0-9]+)s\)[[:space:]]+/\2\t/' \
#     > docs/validation/data/macos-ci-gate-timing/<DATE>-<ubuntu|macos>.tsv
#
# The per-gate seconds come from quality-gates.sh's own `[ok]   ( 70s) <gate>`
# progress lines, which are the SAME figures its `TIMING:` line and its
# $GITHUB_STEP_SUMMARY table are built from — so a captured file's column sum
# equals that run's reported `Ns of gate time` exactly, and this script checks
# that (SUM MISMATCH) rather than assuming it.
#
# Usage:
#   bash workflows/scripts/dev/macos-gate-timing-report.sh [--night YYYY-MM-DD] [--top N]
#   make macos-gate-timing-report
#
#   --night   which night's per-gate delta table to print (default: the latest
#             night present in runs.tsv)
#   --top     rows in the per-gate delta table (default: 12)
#
# Exit codes: 0 = report printed; 1 = a dataset is missing or internally
# inconsistent (named); 2 = usage error.
#
# BSD/macOS-safe: bash 3.2, POSIX join/sort/awk only — no GNU extensions, no
# associative arrays, no `sort -h`.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
DATA_DIR="$REPO_ROOT/docs/validation/data/macos-ci-gate-timing"
RUNS_TSV="$DATA_DIR/runs.tsv"

night=""
top=12

while [ $# -gt 0 ]; do
  case "$1" in
    --night | --top)
      if [ $# -lt 2 ]; then
        echo "macos-gate-timing-report: $1 needs a value" >&2
        exit 2
      fi
      case "$1" in
        --night) night="$2" ;;
        --top) top="$2" ;;
      esac
      shift
      shift
      ;;
    -h | --help)
      sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "macos-gate-timing-report: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

case "$top" in
  '' | *[!0-9]*)
    echo "macos-gate-timing-report: --top must be a non-negative integer, got '$top'" >&2
    exit 2
    ;;
esac

if [ ! -f "$RUNS_TSV" ]; then
  echo "macos-gate-timing-report: missing dataset $RUNS_TSV" >&2
  exit 1
fi

tmp=$(mktemp -d 2>/dev/null) || {
  echo "macos-gate-timing-report: could not allocate a scratch dir" >&2
  exit 1
}
trap 'rm -rf "$tmp"' EXIT

# runs.tsv minus its comment/blank lines — every later pass reads THIS.
awk -F'\t' '!/^#/ && NF > 0' "$RUNS_TSV" >"$tmp/runs" || exit 1

if [ ! -s "$tmp/runs" ]; then
  echo "macos-gate-timing-report: $RUNS_TSV has no data rows" >&2
  exit 1
fi

cut -f1 "$tmp/runs" | sort -u >"$tmp/nights"

if [ -z "$night" ]; then
  night=$(tail -1 "$tmp/nights")
fi

# ── Integrity: every row's per-gate file must exist, and its column sum must
#    equal the gate_cpu_secs the run itself reported. A capture that dropped
#    lines is a wrong answer, not a smaller one, so it is refused loudly.
integrity_rc=0
while IFS=$'\t' read -r d runner _run_id _job_id _q _co _wall _workers cpu count; do
  f="$DATA_DIR/$d-$runner.tsv"
  if [ ! -f "$f" ]; then
    echo "macos-gate-timing-report: MISSING per-gate dataset $f (named by $RUNS_TSV)" >&2
    integrity_rc=1
    continue
  fi
  observed_sum=$(awk -F'\t' '!/^#/ && NF > 1 { s += $1 } END { print s + 0 }' "$f")
  observed_rows=$(awk -F'\t' '!/^#/ && NF > 1' "$f" | wc -l | tr -d ' ')
  if [ "$observed_sum" != "$cpu" ]; then
    echo "macos-gate-timing-report: SUM MISMATCH $f — file sums to ${observed_sum}s, runs.tsv records ${cpu}s" >&2
    integrity_rc=1
  fi
  if [ "$observed_rows" != "$count" ]; then
    echo "macos-gate-timing-report: ROW MISMATCH $f — file has $observed_rows gates, runs.tsv records $count" >&2
    integrity_rc=1
  fi
done <"$tmp/runs"
[ "$integrity_rc" -eq 0 ] || exit 1

rel_data="${DATA_DIR#"$REPO_ROOT"/}"
echo "# macOS-vs-ubuntu nightly gate timing — recomputed from $rel_data"
echo

# ── 1. Run-level table ──────────────────────────────────────────────────────
echo "## Run level (one nightly run = both legs, same commit, same script)"
echo
printf '| Night | ubuntu wall | macOS wall | wall ratio | ubuntu gate-secs | macOS gate-secs | CPU ratio | workers u/m | macOS queue |\n'
printf '|:--|--:|--:|--:|--:|--:|--:|:--:|--:|\n'
while IFS= read -r d; do
  awk -F'\t' -v night="$d" '
    $1 == night && $2 == "ubuntu" { uw = $7; uk = $8; uc = $9 }
    $1 == night && $2 == "macos"  { mw = $7; mk = $8; mc = $9; mq = $5 }
    END {
      printf "| %s | %ds | %ds | %.2fx | %ds | %ds | %.2fx | %d/%d | %ds |\n", \
        night, uw, mw, mw / uw, uc, mc, mc / uc, uk, mk, mq
    }
  ' "$tmp/runs"
done <"$tmp/nights"
echo
echo "wall ratio = macOS wall / ubuntu wall.  CPU ratio = summed per-gate seconds,"
echo "i.e. the same work measured independently of how many workers ran it."
echo "worker count is what quality-gates.sh's pool auto-resolved to on each host."
echo "macOS queue is runner-allocation wait, EXCLUDED from the job's own duration."
echo

# ── 2. The decomposition: does (CPU ratio x worker ratio) explain wall ratio? ─
echo "## Decomposition — wall ratio vs (CPU ratio x worker ratio)"
echo
printf '| Night | CPU ratio | worker ratio | product (predicted) | wall ratio (observed) |\n'
printf '|:--|--:|--:|--:|--:|\n'
while IFS= read -r d; do
  awk -F'\t' -v night="$d" '
    $1 == night && $2 == "ubuntu" { uw = $7; uk = $8; uc = $9 }
    $1 == night && $2 == "macos"  { mw = $7; mk = $8; mc = $9 }
    END {
      cpu = mc / uc; wrk = uk / mk
      printf "| %s | %.2fx | %.2fx | %.2fx | %.2fx |\n", night, cpu, wrk, cpu * wrk, mw / uw
    }
  ' "$tmp/runs"
done <"$tmp/nights"
echo

# ── 3. Per-gate delta for the chosen night ──────────────────────────────────
u_file="$DATA_DIR/$night-ubuntu.tsv"
m_file="$DATA_DIR/$night-macos.tsv"
if [ ! -f "$u_file" ] || [ ! -f "$m_file" ]; then
  echo "macos-gate-timing-report: no per-gate datasets for night '$night'" >&2
  exit 1
fi

awk -F'\t' '!/^#/ && NF > 1 { print $1 "\t" $2 }' "$u_file" | sort -t"$(printf '\t')" -k2 >"$tmp/u"
awk -F'\t' '!/^#/ && NF > 1 { print $1 "\t" $2 }' "$m_file" | sort -t"$(printf '\t')" -k2 >"$tmp/m"
join -t"$(printf '\t')" -1 2 -2 2 "$tmp/u" "$tmp/m" \
  | awk -F'\t' '{ printf "%d\t%d\t%d\t%s\n", $3 - $2, $2, $3, $1 }' \
  | sort -rn >"$tmp/delta"

total_delta=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$tmp/delta")
joined=$(wc -l <"$tmp/delta" | tr -d ' ')

echo "## Per-gate delta, $night ($joined gates present on both legs)"
echo
printf '| macOS − ubuntu | ubuntu | macOS | ratio | share of total delta | Gate |\n'
printf '|--:|--:|--:|--:|--:|:--|\n'
head -"$top" "$tmp/delta" | awk -F'\t' -v tot="$total_delta" '
  { r = ($2 > 0) ? $3 / $2 : 0
    printf "| +%ds | %ds | %ds | %s | %.1f%% | `%s` |\n", $1, $2, $3, (r > 0 ? sprintf("%.2fx", r) : "n/a"), 100 * $1 / tot, $4 }
'
echo
awk -F'\t' -v tot="$total_delta" -v n="$top" '
  NR <= n { head += $1 }
  $1 > 0 { pos++ } $1 == 0 { zero++ } $1 < 0 { neg++ }
  END {
    printf "Total delta: %ds. Top %d gates: %ds (%.0f%% of it).\n", tot, n, head, 100 * head / tot
    printf "Slower on macOS: %d gates. Identical: %d. FASTER on macOS: %d.\n", pos + 0, zero + 0, neg + 0
  }
' "$tmp/delta"
echo

# ── 4. Named gates tracked across every recorded night ──────────────────────
echo "## Named gates across all recorded nights (ubuntu -> macOS seconds)"
echo
printf '| Gate | %s |\n' "$(tr '\n' '|' <"$tmp/nights" | sed 's/|$//' | sed 's/|/ | /g')"
printf '|:--|'
while IFS= read -r _d; do printf ':-:|'; done <"$tmp/nights"
printf '\n'
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  # shellcheck disable=SC2016  # literal Markdown backticks, not command substitution
  printf '| `%s` |' "$gate"
  while IFS= read -r d <&3; do
    u=$(awk -F'\t' -v g="$gate" '!/^#/ && $2 == g { print $1; exit }' "$DATA_DIR/$d-ubuntu.tsv")
    m=$(awk -F'\t' -v g="$gate" '!/^#/ && $2 == g { print $1; exit }' "$DATA_DIR/$d-macos.tsv")
    if [ -n "$u" ] && [ -n "$m" ]; then
      printf ' %s→%s |' "$u" "$m"
    else
      printf ' — |'
    fi
  done 3<"$tmp/nights"
  printf '\n'
done <<'GATES'
bash workflows/scripts/model-comparison/tests/test_score_gate_env.sh
bash workflows/scripts/model-comparison/tests/test_replay_batch.sh
make test-build
make test-cli-subcommands
make test-board
bash workflows/scripts/tests/test_validate_prose_budget.sh
make shellcheck
bash scripts/tests/test_ensure_shellcheck.sh
GATES
echo
echo "The last two rows are hypothesis 2 (the pinned-shellcheck provisioning path)."
echo "Every other row is a gate the delta actually lands on."
