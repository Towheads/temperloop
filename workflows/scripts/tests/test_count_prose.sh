#!/usr/bin/env bash
#
# test_count_prose.sh — fixture + real-tree tests for
# workflows/scripts/count-prose.sh (temperloop#722, item
# prose-baseline-measurement).
#
# Covers: the real-tree happy path (tier-1 + tier-2 report, tier-2 total
# equals the sum of its own per-file lines), the host-determinism guarantee
# across all THREE config-precedence rungs count-prose.sh must neutralize —
# a machine-conf fixture (rung 3), a repo-local-conf fixture (rung 4), AND
# an EXPORTED knob (rung 2 — outranks both file-based rungs, section 4,
# using a newline-bearing value so a real scrub failure is distinguishable
# from wc -l merely being insensitive to a plain-scalar perturbation) must
# all have ZERO effect on the tier-1 count. This is the acceptance-2
# "host-deterministic" property, and this suite running on both the
# ubuntu-latest and macos-latest CI legs is what "verified in CI" means for
# that acceptance bullet. Also covers the missing-input error paths via the
# COUNT_PROSE_ROOT seam. Zero network.
#
# Usage: bash workflows/scripts/tests/test_count_prose.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/count-prose.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else fail_test "$name" "expected '$want', got '$got'"; fi
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# extract_tier1 <output> — the tier-1 line COUNT specifically, anchored past
# "render: " and before " lines". NOT `grep -oE '[0-9]+' | head -1` — the
# first line is literally "TIER-1 kernel-authored composed render: NNN
# lines", and a bare digit-run search matches the constant "1" in "TIER-1"
# BEFORE ever reaching the real count, so every determinism assertion below
# would silently compare 1 == 1 regardless of what the script actually
# printed (caught in review: temperloop#722).
extract_tier1() {
  printf '%s\n' "$1" | sed -n '1p' | sed -E 's/^.*render: ([0-9]+) lines.*$/\1/'
}

# ── 1. real-tree happy path ──────────────────────────────────────────────────
echo "--- 1. real-tree report ---"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "real tree exits 0"
assert_has "$out" "TIER-1" "reports a TIER-1 line"
assert_has "$out" "TIER-2" "reports a TIER-2 section"
assert_has "$out" "claude/CLAUDE.kernel.md" "per-file table includes the kernel doc"
assert_has "$out" "claude/agents/architecture-reviewer.md" "per-file table includes an agent charter"

tier1_count="$(extract_tier1 "$out")"
case "$tier1_count" in
  ''|*[!0-9]*) fail_test "tier-1 count is a positive integer" "got '$tier1_count'" ;;
  *)
    if [ "$tier1_count" -gt 0 ]; then
      ok "tier-1 count is a positive integer"
    else
      fail_test "tier-1 count is a positive integer" "got '$tier1_count'"
    fi
    ;;
esac

# tier-2 total must equal the sum of its own per-file counts (internal
# consistency — no file silently dropped or double-counted).
sum_lines="$(printf '%s\n' "$out" | awk '/^TIER-2 per-file/{p=1;next} /^$/{p=0} p{sum+=$1} END{print sum+0}')"
reported_total="$(printf '%s\n' "$out" | grep -oE 'TIER-2 total: [0-9]+' | sed -E 's/^TIER-2 total: //')"
assert_eq "$sum_lines" "$reported_total" "tier-2 total equals the sum of its per-file lines"

# ── 2. host-determinism: a machine-conf fixture perturbing the knobs must
#      have ZERO effect on the tier-1 count ─────────────────────────────────
echo "--- 2. host-determinism (machine conf) ---"
cat > "$TMP/machine.sh" <<'EOF'
DISPLAY_TZ=UTC
EPIC_MIN_SUBUNITS=99
EOF
out_perturbed="$(BUILD_CONFIG_MACHINE="$TMP/machine.sh" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "perturbed-machine-conf run exits 0"
tier1_perturbed="$(extract_tier1 "$out_perturbed")"
assert_eq "$tier1_perturbed" "$tier1_count" "machine-conf perturbation does not move the tier-1 count"

# ── 3. host-determinism: a repo-local-conf fixture perturbing the knobs must
#      also have ZERO effect ────────────────────────────────────────────────
echo "--- 3. host-determinism (repo-local conf) ---"
cat > "$TMP/local.sh" <<'EOF'
DISPLAY_TZ=Antarctica/Troll
EPIC_MIN_SUBUNITS=1
EOF
out_local="$(BUILD_CONFIG_LOCAL="$TMP/local.sh" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "perturbed-repo-local-conf run exits 0"
tier1_local="$(extract_tier1 "$out_local")"
assert_eq "$tier1_local" "$tier1_count" "repo-local-conf perturbation does not move the tier-1 count"

# ── 4. host-determinism: an EXPORTED knob (rung 2, outranks the rung-3/4
#      config-FILE pinning covered above) must ALSO have zero effect. Uses a
#      newline-bearing value specifically — a plain scalar perturbation
#      (e.g. "99") can't distinguish "the env var was actually scrubbed"
#      from "wc -l is merely insensitive to this particular value"; a
#      newline embedded IN the value, if it ever reached the render, would
#      itself add a line to the rendered doc and move the wc -l count
#      (caught in review: temperloop#722, the same case the reviewer
#      demonstrated moves tier-1 338->341 without the rung-2 scrub) ────────
echo "--- 4. host-determinism (exported knob, rung 2) ---"
out_env="$(EPIC_MIN_SUBUNITS=$'99\n99' bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "perturbed-exported-knob run exits 0"
tier1_env="$(extract_tier1 "$out_env")"
assert_eq "$tier1_env" "$tier1_count" "an exported EPIC_MIN_SUBUNITS (with an embedded newline) does not move the tier-1 count"

# ── 5. missing-input error paths via COUNT_PROSE_ROOT ───────────────────────
echo "--- 5. missing-input error paths ---"

# 5a. no claude/CLAUDE.kernel.md at all.
NOKERNEL="$TMP/no-kernel-repo"
mkdir -p "$NOKERNEL/.git"
out="$(COUNT_PROSE_ROOT="$NOKERNEL" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "missing kernel doc exits 1"
assert_has "$out" "kernel doc not found" "missing kernel doc named"

# 5b. kernel doc present, compose seam (install-claude-md.sh) missing.
NOSEAM="$TMP/no-seam-repo"
mkdir -p "$NOSEAM/.git" "$NOSEAM/claude" "$NOSEAM/workflows/scripts"
printf '# fixture kernel doc\n' > "$NOSEAM/claude/CLAUDE.kernel.md"
out="$(COUNT_PROSE_ROOT="$NOSEAM" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "missing compose seam exits 1"
assert_has "$out" "compose seam not found" "missing compose seam named"

# 5c. both present, but the root is not a git checkout at all.
NOTGIT="$TMP/not-a-git-repo"
mkdir -p "$NOTGIT/claude"
printf '# fixture kernel doc\n' > "$NOTGIT/claude/CLAUDE.kernel.md"
mkdir -p "$NOTGIT/workflows/scripts"
cp "$REPO/workflows/scripts/install-claude-md.sh" "$NOTGIT/workflows/scripts/install-claude-md.sh"
out="$(COUNT_PROSE_ROOT="$NOTGIT" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "non-git root exits 1"
assert_has "$out" "not a git checkout" "non-git root named"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_count_prose: FAIL"
  exit 1
fi
echo "test_count_prose: OK"
