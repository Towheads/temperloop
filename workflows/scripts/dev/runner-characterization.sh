#!/usr/bin/env bash
#
# runner-characterization.sh — record WHAT KIND OF MACHINE a CI leg actually
# got, and how fast it does the two things this repo's gate suite does most of
# (temperloop#968, measurement phase).
#
# WHY THIS EXISTS, precisely. `nightly-macos.yml` already publishes a per-gate
# wall-clock table on both legs (QUALITY_GATES_STEP_SUMMARY=1), and that table
# localises the macOS-vs-ubuntu delta to named gates. It leaves exactly two
# things unmeasurable from the outside, both of which the reintroduction
# decision depends on:
#
#   1. CORE COUNT IS HIDDEN BY A CLAMP. The gate pool's `auto` width is
#      `min(detected cores, _gate_pool_auto_cap)` and that cap is 4
#      (workflows/scripts/lib/gate-pool.sh). ubuntu resolving to 4 workers and
#      macOS to 3 is consistent with "4 cores vs 3 cores" AND with "8 cores
#      clamped to 4 vs 3 cores" — which are different problems with different
#      fixes. This script prints the RAW detected count next to the clamped
#      one, so the ambiguity is closed by a number instead of by inference.
#   2. WHICH PRIMITIVE IS SLOW IS UNMEASURED. The measured delta is not
#      uniform: `make shellcheck` — one compiled binary over the whole tree —
#      is at parity or FASTER on macOS, while bash test harnesses run 1.5x-4x
#      slower. That contrast is a hypothesis about process-spawn and
#      filesystem-syscall cost, and a hypothesis is not a measurement. The two
#      throughput probes below turn it into one.
#
# NOT A GATE, and never allowed to become one: it prints facts, asserts
# nothing, and always exits 0 (a probe that could redden `nightly-macos` would
# trade real BSD-dialect coverage for a benchmark, which is a bad trade). It
# adds a bounded ~10s per leg — a fixed measurement WINDOW, not a fixed amount
# of work, so the cost cannot grow on the slower host.
#
# Usage:
#   bash workflows/scripts/dev/runner-characterization.sh
#
# Takes no arguments and reads no configuration: both probes run for a FIXED
# 4-second window, deliberately not a tunable — a window one leg could be run
# with and the other not is a window that makes the two incomparable, which is
# the only property this probe has. When GitHub Actions has set
# $GITHUB_STEP_SUMMARY the report is appended there as well as printed.
#
# Exit codes: always 0.
#
# BSD/macOS-safe: bash 3.2, POSIX only. Deliberately no sub-second clock —
# `date +%s` granularity is 1s on both hosts, so both probes count OPERATIONS
# COMPLETED IN A FIXED WINDOW rather than timing a fixed operation count.

set -u

window=4

os_name=$(uname -s 2>/dev/null || echo unknown)
os_rel=$(uname -r 2>/dev/null || echo unknown)
arch=$(uname -m 2>/dev/null || echo unknown)

cpu_brand="unknown"
cores_logical=""
cores_physical=""
mem_bytes=""

if [ "$os_name" = "Darwin" ]; then
  cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)
  cores_logical=$(sysctl -n hw.logicalcpu 2>/dev/null || true)
  cores_physical=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
else
  cpu_brand=$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
  [ -n "$cpu_brand" ] || cpu_brand="unknown"
  cores_logical=$(nproc 2>/dev/null || true)
  cores_physical="$cores_logical"
  mem_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  [ -n "$mem_kb" ] && mem_bytes=$((mem_kb * 1024))
fi

[ -n "$cores_logical" ] || cores_logical="?"
[ -n "$cores_physical" ] || cores_physical="?"
mem_gb="?"
if [ -n "$mem_bytes" ]; then
  mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
fi

# The clamped width the gate pool would actually use, read from the real
# resolver rather than re-derived here (one source of truth, temperloop#1025).
pool_width="?"
pool_cap="?"
pool_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/gate-pool.sh"
if [ -f "$pool_lib" ]; then
  # shellcheck source=/dev/null
  . "$pool_lib" 2>/dev/null || true
  if command -v gate_pool_resolve_jobs >/dev/null 2>&1; then
    pool_width=$(gate_pool_resolve_jobs auto 2>/dev/null || echo '?')
  fi
  pool_cap=$(awk -F= '/^_gate_pool_auto_cap=/ { print $2; exit }' "$pool_lib" 2>/dev/null || echo '?')
  [ -n "$pool_cap" ] || pool_cap="?"
fi

# ── Probe 1: process spawn throughput ───────────────────────────────────────
# The dominant primitive in this repo's slow gates: every one of them is a bash
# harness that shells out per assertion. Batched 50-at-a-time so the loop's own
# `date` call is <2% of the work being measured.
spawn_ops=0
spawn_end=$(($(date +%s) + window))
while [ "$(date +%s)" -lt "$spawn_end" ]; do
  i=0
  while [ "$i" -lt 50 ]; do
    /bin/sh -c ':'
    i=$((i + 1))
  done
  spawn_ops=$((spawn_ops + 50))
done
spawn_rate=$((spawn_ops / window))

# ── Probe 2: filesystem create/stat/unlink throughput ───────────────────────
# The other primitive the slow gates lean on: fixture trees built and torn down
# per test case. Run inside a scratch dir so it never touches the checkout.
fs_dir=$(mktemp -d 2>/dev/null || echo "")
fs_rate="n/a"
if [ -n "$fs_dir" ]; then
  fs_ops=0
  fs_end=$(($(date +%s) + window))
  while [ "$(date +%s)" -lt "$fs_end" ]; do
    i=0
    while [ "$i" -lt 200 ]; do
      : >"$fs_dir/probe.$i"
      test -f "$fs_dir/probe.$i"
      rm -f "$fs_dir/probe.$i"
      i=$((i + 1))
    done
    fs_ops=$((fs_ops + 200))
  done
  fs_rate=$((fs_ops / window))
  rm -rf "$fs_dir"
fi

label="${RUNNER_OS:-$os_name}" # setting:exempt — RUNNER_OS is GitHub-Actions-injected (a harness-provided fact), not a tunable this repo owns; $os_name is the off-CI fallback

emit() {
  printf 'Runner characterization (%s) — temperloop#968\n\n' "$label"
  printf '| Fact | Value |\n'
  printf '|:--|:--|\n'
  printf '| OS / kernel / arch | %s %s %s |\n' "$os_name" "$os_rel" "$arch"
  printf '| CPU | %s |\n' "$cpu_brand"
  printf '| Cores (logical / physical) | %s / %s |\n' "$cores_logical" "$cores_physical"
  printf '| Memory | %s GiB |\n' "$mem_gb"
  # shellcheck disable=SC2016  # literal Markdown backticks, not command substitution
  printf '| Gate-pool width `auto` resolves to | %s (cap %s) |\n' "$pool_width" "$pool_cap"
  printf '| Bash | %s |\n' "${BASH_VERSION:-unknown}" # setting:exempt — BASH_VERSION is set by bash itself; this line REPORTS it and configures nothing
  # shellcheck disable=SC2016  # literal Markdown backticks, not command substitution
  printf '| Process spawns/sec (`/bin/sh -c :`) | %s |\n' "$spawn_rate"
  printf '| File create+stat+unlink/sec | %s |\n' "$fs_rate"
  printf '\n'
  printf 'Both rates are operations completed in a fixed %ss window, so the probe\n' "$window"
  printf 'costs the same on the slow host as on the fast one. Cores logical vs the\n'
  printf 'resolved pool width is the clamp check: a width BELOW the logical count\n'
  printf 'means the cap, not the hardware, is setting this run parallelism.\n'
}

emit
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then # setting:exempt — GITHUB_STEP_SUMMARY is the GitHub-injected step-summary sink path, not a tunable
  {
    printf '## '
    emit
  } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

exit 0
