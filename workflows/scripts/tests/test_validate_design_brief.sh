#!/usr/bin/env bash
#
# test_validate_design_brief.sh — fixture tests for
# workflows/scripts/validate-design-brief.sh (temperloop#216).
#
# Covers both checks the validator runs:
#   (A) schema citation check — against the real claude/design-schema.md
#       (must stay clean) and against a fixture with a deliberately dangling
#       citation (must fail, DANGLING-CITATION).
#   (B) brief conformance check — against a purpose-built minimal conformant
#       fixture (must pass) and three distinct failure-shaped fixtures: a
#       dropped disposition line (MISSING-DISPOSITION), an absent heading
#       (MISSING-DIMENSION), and a malformed disposition value
#       (BAD-DISPOSITION).
# Also proves the bare CI-mode invocation (no flags) is what quality-gates.sh
# runs and stays green against the real tree.
#
# Zero network, zero git-repo scaffolding needed — the validator reads plain
# files, not a git index, so fixtures are just files under
# workflows/scripts/tests/fixtures/.
#
# Usage: bash workflows/scripts/tests/test_validate_design_brief.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-design-brief.sh"
BRIEF_FIXTURES="$REPO/workflows/scripts/tests/fixtures/design-briefs"
SCHEMA_FIXTURES="$REPO/workflows/scripts/tests/fixtures/design-schema"

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
assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

out=""
rc=0
run() {
  rc=0
  out="$(DESIGN_SCHEMA_ROOT="$REPO" bash "$SCRIPT" "$@" 2>&1)" || rc=$?
}

# ── 1. bare CI-mode invocation: schema citation check on the real tree ──────
echo "--- 1. bare invocation (CI mode) against the real schema ---"
run
assert_rc "$rc" 0 "bare invocation exits 0 on the real tree"
assert_has "$out" "validate-design-brief: OK" "bare invocation says OK"
assert_lacks "$out" "DANGLING-CITATION" "real schema has no dangling citations"

# ── 2. schema citation check: real schema explicitly via --schema ───────────
echo "--- 2. --schema on the real claude/design-schema.md ---"
run --schema "$REPO/claude/design-schema.md"
assert_rc "$rc" 0 "real schema file exits 0"
assert_has "$out" "validate-design-brief: OK" "real schema says OK"

# ── 3. schema citation check: fixture with a dangling citation ──────────────
echo "--- 3. --schema on the dangling-citation fixture ---"
run --schema "$SCHEMA_FIXTURES/dangling-citation.md"
assert_rc "$rc" 1 "dangling-citation fixture exits 1"
assert_has "$out" "DANGLING-CITATION  dimension 2 — 'workflows/scripts/validate-nonexistent-thing.sh'" "dangling citation named"
assert_lacks "$out" "dimension 1 —" "the real citation in row 1 is NOT flagged"

# ── 4. brief conformance: minimal conformant fixture passes ─────────────────
echo "--- 4. --brief on the minimal-conformant fixture ---"
run --brief "$BRIEF_FIXTURES/minimal-conformant.md"
assert_rc "$rc" 0 "conformant fixture exits 0"
assert_has "$out" "validate-design-brief: OK" "conformant fixture says OK"
assert_has "$out" "16 dimension heading(s) found" "all 16 dimensions counted"

# ── 5. brief conformance: dropped disposition line ───────────────────────────
echo "--- 5. --brief on missing-dimension (dropped disposition, dim 9) ---"
run --brief "$BRIEF_FIXTURES/missing-dimension.md"
assert_rc "$rc" 1 "missing-dimension fixture exits 1"
assert_has "$out" "MISSING-DISPOSITION  missing-dimension.md dimension 9" "missing disposition named on dim 9"

# ── 6. brief conformance: heading entirely absent ────────────────────────────
echo "--- 6. --brief on missing-heading (no '## 12.' heading at all) ---"
run --brief "$BRIEF_FIXTURES/missing-heading.md"
assert_rc "$rc" 1 "missing-heading fixture exits 1"
assert_has "$out" "MISSING-DIMENSION  missing-heading.md — kernel dimension 12" "missing dimension 12 named"

# ── 7. brief conformance: malformed disposition grammar ──────────────────────
echo "--- 7. --brief on bad-grammar (dim 6 disposition doesn't match the grammar) ---"
run --brief "$BRIEF_FIXTURES/bad-grammar.md"
assert_rc "$rc" 1 "bad-grammar fixture exits 1"
assert_has "$out" "BAD-DISPOSITION  bad-grammar.md dimension 6 — 'disposition: skipped'" "bad disposition value named"

# ── 7b. brief conformance: bare-integer heading beyond the kernel count ──────
echo "--- 7b. --brief on bare-integer-overflow ('## 17.' bare integer) ---"
run --brief "$BRIEF_FIXTURES/bare-integer-overflow.md"
assert_rc "$rc" 1 "bare-integer-overflow fixture exits 1"
assert_has "$out" "UNKNOWN-DIMENSION  bare-integer-overflow.md — '## 17.'" "bare integer 17 named"
assert_has "$out" "letter-suffixed, e.g. 16a" "failure points at the sanctioned overlay form"

# ── 7c. brief conformance: letter-suffixed overlay dimension is sanctioned ───
echo "--- 7c. --brief on overlay-added ('## 16a.' letter-suffixed) ---"
run --brief "$BRIEF_FIXTURES/overlay-added.md"
assert_rc "$rc" 0 "overlay-added fixture exits 0"
assert_has "$out" "validate-design-brief: OK" "overlay-added fixture says OK"
assert_has "$out" "17 dimension heading(s) found" "16 kernel + 1 overlay heading counted"

# ── 7d. anti-drift: renamed schema section must not pass vacuously ───────────
echo "--- 7d. --schema on a renamed-section schema (zero parsed rows) ---"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
sed 's/^## Kernel dimension list$/## Renamed dimension section/' \
  "$REPO/claude/design-schema.md" > "$SCRATCH/renamed-schema.md"
run --schema "$SCRATCH/renamed-schema.md"
assert_rc "$rc" 1 "renamed-section schema exits 1 (no vacuous pass)"
assert_has "$out" "NO-DIMENSION-ROWS" "zero-row parse named"

# ── 7e. anti-drift: kernel dimension count drift fails ci mode ────────────────
echo "--- 7e. ci mode against a schema copy with a kernel row removed ---"
mkdir -p "$SCRATCH/driftroot/claude"
# Drop dimension 16's table row (bare-integer rows go 17 -> 16; the real
# schema now carries dimensions 0..16 inclusive per temperloop#508).
grep -v '^| 16 |' "$REPO/claude/design-schema.md" \
  > "$SCRATCH/driftroot/claude/design-schema.md"
rc=0
out="$(DESIGN_SCHEMA_ROOT="$SCRATCH/driftroot" bash "$SCRIPT" 2>&1)" || rc=$?
assert_rc "$rc" 1 "row-removed schema fails ci mode"
assert_has "$out" "DIM-COUNT-DRIFT" "count drift named"
assert_has "$out" "16 bare-integer kernel row(s), script encodes KERNEL_DIM_COUNT=17" "drift counts named"

# ── 7f. anti-drift: --schema fixture mode does NOT enforce the count ─────────
echo "--- 7f. --schema fixture mode exempt from the count check ---"
run --schema "$SCHEMA_FIXTURES/dangling-citation.md"
assert_lacks "$out" "DIM-COUNT-DRIFT" "2-row fixture not flagged for count drift"

# ── 8. brief conformance: brief file itself absent ───────────────────────────
echo "--- 8. --brief on a nonexistent path ---"
run --brief "$BRIEF_FIXTURES/does-not-exist.md"
assert_rc "$rc" 1 "nonexistent brief file exits 1"
assert_has "$out" "BRIEF-NOT-FOUND" "brief-not-found named"

# ── 9. usage errors ───────────────────────────────────────────────────────────
echo "--- 9. usage errors ---"
run --brief
assert_rc "$rc" 2 "--brief with no path exits 2"
run --bogus-flag
assert_rc "$rc" 2 "unknown flag exits 2"

# ── 10. bare-filename citation in a tree LARGER than the pipe buffer (#358) ───
#
# Regression guard. resolve_citation's bare-filename branch used to pipe
# `git ls-files` into `grep -q`. `grep -q` exits on the first match and closes
# the pipe; the producer, still writing, dies of SIGPIPE (141), and
# `set -o pipefail` promotes that 141 to the pipeline's status — so a citation
# that DID match was reported DANGLING.
#
# TWO conditions must BOTH hold or this test passes vacuously against the very
# bug it guards:
#
#   1. The listing must EXCEED the pipe buffer (~64KiB). Under it the producer
#      writes everything and exits before grep can close the pipe, so no
#      SIGPIPE. This repo's own tree (~15KiB) is comfortably under — exactly
#      why the defect shipped green and only surfaced in a composed overlay
#      tree (~74KiB).
#   2. The match must occur EARLY in the listing. `git ls-files` sorts, so a
#      sentinel sorting last means grep reads to the end, the producer finishes
#      cleanly, and again no SIGPIPE — a 64KiB+ tree alone is NOT sufficient.
#      Hence the `aaa-` prefix: it sorts ahead of the padding, so grep -q exits
#      on the first line while ~87KiB is still queued behind it.
#
# Both were verified to fail against the pre-fix code before this test landed.
echo "--- 10. bare-filename citation resolves in a >64KiB tree (#358) ---"

BIG="$SCRATCH/bigrepo"   # reuse SCRATCH: it already owns the EXIT trap
mkdir -p "$BIG"
(
  cd "$BIG" || exit 1
  git init -q .
  # Long path segments pad the listing to the target with few files, keeping
  # the scaffold fast: ~200 chars/path x 400 files ~= 80KiB > 65536.
  pad="padding-segment-to-lengthen-each-tracked-path-so-the-listing-crosses-the-pipe-buffer-threshold-quickly"
  mkdir -p "$pad/$pad"
  i=0
  while [ "$i" -lt 400 ]; do
    : > "$pad/$pad/filler-$i.sh"
    i=$((i + 1))
  done
  # The sentinel: a bare filename the fixture cites — tracked, resolvable, and
  # deliberately sorting FIRST (see condition 2 above) so grep -q exits while
  # the producer is still writing.
  : > aaa-sentinel-target-file.sh
  git add -A >/dev/null 2>&1
) || fail_test "10: setup" "could not scaffold the synthetic repo"

listing_bytes="$( (cd "$BIG" && git ls-files) | wc -c | tr -d ' ' )"
if [ "$listing_bytes" -gt 65536 ]; then
  ok "10a: synthetic tree exceeds the 64KiB pipe buffer ($listing_bytes bytes)"
else
  fail_test "10a: synthetic tree exceeds the 64KiB pipe buffer" \
    "listing is only $listing_bytes bytes — under the buffer, #358 cannot reproduce and 10b/10c would pass vacuously"
fi

cat > "$SCRATCH/schema-bare-citation.md" <<'FIXTURE'
# Fixture — schema table citing a bare filename

Exercises resolve_citation's bare-filename branch (no directory component),
which resolves by basename search over the tracked tree — the only branch that
shells out to `git ls-files`, and so the only one #358 could affect.

## Kernel dimension list

| # | Dimension | What it answers | Enforcing gate |
|---|---|---|---|
| 1 | **Fixture dimension one** | Fixture question one. | `aaa-sentinel-target-file.sh` — a bare filename, tracked in the synthetic root, sorting first; must resolve clean. |
FIXTURE

rc=0
out="$(DESIGN_SCHEMA_ROOT="$BIG" bash "$SCRIPT" --schema "$SCRATCH/schema-bare-citation.md" 2>&1)" || rc=$?
assert_rc "$rc" 0 "10b: bare-filename citation resolves in a >64KiB tree"
assert_lacks "$out" "DANGLING-CITATION" "10c: no false DANGLING-CITATION from a SIGPIPE'd producer"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_validate_design_brief: FAIL"
  exit 1
fi
echo "test_validate_design_brief: OK"
