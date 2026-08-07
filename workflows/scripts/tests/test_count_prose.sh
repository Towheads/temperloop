#!/usr/bin/env bash
#
# test_count_prose.sh — fixture + real-tree tests for
# workflows/scripts/count-prose.sh (temperloop#722, item
# prose-baseline-measurement; temperloop#827, epic #810 P1 extends this
# suite to the manifest-driven SESSION-START CONTRIBUTORS section).
#
# Covers: the real-tree happy path (tier-1 + tier-2 report, tier-2 total
# equals the sum of its own per-file lines), the host-determinism guarantee
# across all THREE config-precedence layers count-prose.sh must neutralize —
# a machine-conf fixture (layer 3), a repo-local-conf fixture (layer 4), AND
# an EXPORTED setting (layer 2 — outranks both file-based layers, section 4,
# using a newline-bearing value so a real scrub failure is distinguishable
# from wc -l merely being insensitive to a plain-scalar perturbation) must
# all have ZERO effect on the tier-1 count. This is the acceptance-2
# "host-deterministic" property, and this suite running on both the
# ubuntu-latest and macos-latest CI legs is what "verified in CI" means for
# that acceptance bullet. Also covers the missing-input error paths via the
# COUNT_PROSE_ROOT seam. Zero network.
#
# temperloop#827 additions (section 6+): the SESSION-START CONTRIBUTORS
# report — its byte total is internally consistent (equals the sum of its
# own per-row bytes), the SAME three host-determinism fixtures used for
# tier-1 above have zero effect on the harness-auto byte subtotal (this
# section reads no build.config.sh setting at all, so this is trivially
# true, but pinned so a future regression that wires one in is caught), the
# byte->token proxy ratio is RE-DERIVED from the reported live byte and word
# counts (never a stale/cached number), and the ratio-computation source
# line itself carries no bare numeric literal (grepped directly out of
# count-prose.sh).
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
# assert_matches <value> <ere> <name> — the value must be NON-EMPTY and
# match the given extended regex. This exists because every `grep -oE …
# | sed …` extraction below degrades to an empty string when the line it
# targets is simply ABSENT from the output (e.g. the SESSION-START
# CONTRIBUTORS section silently missing, per the review round's bash-3.2
# unbound-variable finding) — and `assert_eq ""` "" then reports `ok`,
# indistinguishable from "the two runs produced identical real numbers".
# Every numeric extraction a determinism/ratio assertion below depends on
# is asserted non-empty-and-well-formed with this FIRST, so "identical" and
# "both absent" can no longer read as the same result.
assert_matches() {
  local got="$1" ere="$2" name="$3"
  case "$got" in
    '') fail_test "$name" "value is EMPTY (the line this was extracted from is likely missing from the output entirely — not a format mismatch)" ;;
    *)
      if grep -qE "^${ere}\$" <<<"$got"; then
        ok "$name"
      else
        fail_test "$name" "expected to match /$ere/, got '$got'"
      fi
      ;;
  esac
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

# ── 2. host-determinism: a machine-conf fixture perturbing the settings must
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

# ── 3. host-determinism: a repo-local-conf fixture perturbing the settings must
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

# ── 4. host-determinism: an EXPORTED setting (layer 2, outranks the layer-3/4
#      config-FILE pinning covered above) must ALSO have zero effect. Uses a
#      newline-bearing value specifically — a plain scalar perturbation
#      (e.g. "99") can't distinguish "the env var was actually scrubbed"
#      from "wc -l is merely insensitive to this particular value"; a
#      newline embedded IN the value, if it ever reached the render, would
#      itself add a line to the rendered doc and move the wc -l count
#      (caught in review: temperloop#722, the same case the reviewer
#      demonstrated moves tier-1 338->341 without the layer-2 scrub) ────────
echo "--- 4. host-determinism (exported setting, layer 2) ---"
out_env="$(EPIC_MIN_SUBUNITS=$'99\n99' bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "perturbed-exported-setting run exits 0"
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

# 5d. kernel doc + compose seam + a REAL git checkout (tier-1/tier-2 must
# actually succeed, unlike 5a-5c above) all present, but the
# contributor-manifest.tsv is missing. Unlike kernel_doc/install_script/
# git-checkout above, a missing manifest is a SOFT dependency (count-prose.sh
# is also invoked by validate-prose-budget.sh against minimal scratch trees
# that exercise only tier-1/tier-2 and carry no contributor-manifest.tsv of
# their own) — it degrades the SESSION-START CONTRIBUTORS section to a
# skipped, clearly-labeled no-op on stderr, exit 0, never a script-wide
# failure.
NOMANIFEST="$TMP/no-manifest-repo"
mkdir -p "$NOMANIFEST/claude" "$NOMANIFEST/workflows/scripts"
printf '# fixture kernel doc\n' > "$NOMANIFEST/claude/CLAUDE.kernel.md"
cp "$REPO/workflows/scripts/install-claude-md.sh" "$NOMANIFEST/workflows/scripts/install-claude-md.sh"
git -C "$NOMANIFEST" init -q
git -C "$NOMANIFEST" config user.email test@example.com
git -C "$NOMANIFEST" config user.name test
git -C "$NOMANIFEST" add -A
git -C "$NOMANIFEST" commit -q -m fixture
out="$(COUNT_PROSE_ROOT="$NOMANIFEST" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "missing contributor manifest degrades gracefully (exit 0, not a script-wide failure)"
assert_has "$out" "TIER-1" "missing-manifest run still reports TIER-1 (the soft-dependency contract)"
assert_has "$out" "TIER-2" "missing-manifest run still reports TIER-2 (the soft-dependency contract)"
assert_has "$out" "contributor manifest not found" "missing contributor manifest named"
assert_has "$out" "skipping SESSION-START CONTRIBUTORS section" "missing-manifest run names the section it skipped"

# ── 6. SESSION-START CONTRIBUTORS: real-tree happy path ─────────────────────
echo "--- 6. SESSION-START CONTRIBUTORS real-tree report ---"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "real tree (contributor section) exits 0"
assert_has "$out" "SESSION-START CONTRIBUTORS" "reports a SESSION-START CONTRIBUTORS section"
assert_has "$out" "CLAUDE.md" "contributor report includes the root pointer"
assert_has "$out" "claude/agents/reviewers/python-reviewer.md" "contributor report includes an inert-catalog reviewer (the discovery-leak surface)"
assert_has "$out" "[harness-auto] SESSION-START CONTRIBUTOR TOTAL" "contributor report has a harness-auto total line"
assert_has "$out" "byte->token proxy ratio" "contributor report has a byte->token ratio line"

# Internal consistency: the harness-auto TOTAL must equal the sum of every
# contributor row's own byte count (no row silently dropped/double-counted)
# — same shape as the tier-2 internal-consistency assertion above.
sum_contrib_bytes="$(printf '%s\n' "$out" | awk '
  /^SESSION-START CONTRIBUTORS/{p=1; next}
  /^\[harness-auto\] SUBTOTAL/{p=0}
  p && /^ *[0-9]+  /{sum+=$1}
  END{print sum+0}
')"
reported_contrib_total="$(printf '%s\n' "$out" | grep -oE '\[harness-auto\] SESSION-START CONTRIBUTOR TOTAL: [0-9]+' | sed -E 's/^.*TOTAL: //')"
assert_matches "$reported_contrib_total" '[0-9]+' "harness-auto total line is present and numeric (not silently absent)"
assert_eq "$sum_contrib_bytes" "$reported_contrib_total" "harness-auto contributor total equals the sum of its own per-row bytes"

contrib_total_baseline="$reported_contrib_total"

# ── 7. SESSION-START CONTRIBUTORS: host-determinism (reuses the tier-1
#      fixtures 2-4 above — this section reads no build.config.sh setting
#      at all today, so this pins that against a future regression) ────────
echo "--- 7. SESSION-START CONTRIBUTORS host-determinism ---"
out_c2="$(BUILD_CONFIG_MACHINE="$TMP/machine.sh" bash "$SCRIPT" 2>&1)"
c2_total="$(printf '%s\n' "$out_c2" | grep -oE '\[harness-auto\] SESSION-START CONTRIBUTOR TOTAL: [0-9]+' | sed -E 's/^.*TOTAL: //')"
assert_matches "$c2_total" '[0-9]+' "machine-conf run's harness-auto total line is present and numeric"
assert_eq "$c2_total" "$contrib_total_baseline" "machine-conf perturbation does not move the contributor byte total"

out_c3="$(BUILD_CONFIG_LOCAL="$TMP/local.sh" bash "$SCRIPT" 2>&1)"
c3_total="$(printf '%s\n' "$out_c3" | grep -oE '\[harness-auto\] SESSION-START CONTRIBUTOR TOTAL: [0-9]+' | sed -E 's/^.*TOTAL: //')"
assert_matches "$c3_total" '[0-9]+' "repo-local-conf run's harness-auto total line is present and numeric"
assert_eq "$c3_total" "$contrib_total_baseline" "repo-local-conf perturbation does not move the contributor byte total"

out_c4="$(EPIC_MIN_SUBUNITS=$'99\n99' bash "$SCRIPT" 2>&1)"
c4_total="$(printf '%s\n' "$out_c4" | grep -oE '\[harness-auto\] SESSION-START CONTRIBUTOR TOTAL: [0-9]+' | sed -E 's/^.*TOTAL: //')"
assert_matches "$c4_total" '[0-9]+' "exported-EPIC_MIN_SUBUNITS run's harness-auto total line is present and numeric"
assert_eq "$c4_total" "$contrib_total_baseline" "an exported EPIC_MIN_SUBUNITS does not move the contributor byte total"

# ── 8. byte->token ratio: re-derivable at runtime, no baked literal ─────────
echo "--- 8. byte->token ratio re-derivation + no-literal pin ---"

# 8a. recompute the ratio from the LIVE byte and word counts the report
# itself printed, and assert it matches the reported ratio exactly — proves
# the number is genuinely derived from those two live counts, not a stale
# or hardcoded figure.
ratio_line="$(printf '%s\n' "$out" | grep -E '^\[harness-auto\] byte->token proxy ratio')"
# The line itself must exist before any field is pulled out of it — a
# missing line (e.g. bash 3.2's empty-array crash silently deleting the
# whole SESSION-START CONTRIBUTORS section, the exact failure this
# suite must catch) would otherwise make every extraction below an empty
# string, and `expected_ratio`'s `awk` division would divide by an empty
# `w` (== 0), printing `awk: division by zero` to STDERR while `$(...)`
# still captures whatever partial stdout awk produced — the two empty/
# malformed strings then compared equal and this test went green with the
# section entirely absent (caught in review).
if [ -z "$ratio_line" ]; then
  fail_test "byte->token ratio line is present" "no line matching '^[harness-auto] byte->token proxy ratio' in the report — SESSION-START CONTRIBUTORS section likely missing entirely"
else
  ok "byte->token ratio line is present"
fi
ratio_bytes="$(printf '%s\n' "$ratio_line" | sed -E 's/^.*bytes=([0-9]+).*$/\1/')"
ratio_words="$(printf '%s\n' "$ratio_line" | sed -E 's/^.*words=([0-9]+).*$/\1/')"
reported_ratio="$(printf '%s\n' "$ratio_line" | sed -E 's/^.*ratio=([0-9]+\.[0-9]+).*$/\1/')"
assert_matches "$ratio_bytes" '[0-9]+' "ratio line's bytes= field is present and numeric"
assert_matches "$ratio_words" '[1-9][0-9]*' "ratio line's words= field is present and a positive integer (never zero — guards the recompute division below)"
assert_matches "$reported_ratio" '[0-9]+\.[0-9]+' "ratio line's ratio= field is present and well-formed"
expected_ratio="$(awk -v b="$ratio_bytes" -v w="$ratio_words" 'BEGIN{printf "%d.%02d", int(b*100/w)/100, int(b*100/w)%100}')"
assert_eq "$reported_ratio" "$expected_ratio" "ratio recomputed from the report's own live byte+word counts matches the reported ratio"
assert_eq "$ratio_bytes" "$contrib_total_baseline" "the ratio line's byte count matches the harness-auto total"

# 8b. the RATIO-COMPUTATION source line itself carries no bare numeric
# literal — grepped directly from count-prose.sh, not from its output. This
# is temperloop#827 acceptance 4's "asserts no numeric literal appears in
# the ratio's own source line" — the divisor/scale must be variables
# (ratio_scale, class_total_words), never an inline magic number.
# shellcheck disable=SC2016  # intentional: single-quoted so grep -F matches the literal text, not shell-expanded
ratio_source_line="$(grep -F 'ratio_scaled=$((class_total_bytes * ratio_scale / class_total_words))' "$SCRIPT")"
case "$ratio_source_line" in
  '') fail_test "ratio-computation source line exists" "line not found in $SCRIPT (did the implementation shape change?)" ;;
  *[0-9]*) fail_test "ratio-computation source line has no bare numeric literal" "found a digit in: $ratio_source_line" ;;
  *) ok "ratio-computation source line has no bare numeric literal" ;;
esac

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_count_prose: FAIL"
  exit 1
fi
echo "test_count_prose: OK"
