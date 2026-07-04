#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/plan.sh — the build Step-1 plan
# parse/validate + dependency-level toposort and the in-band sentinel writeback
# CLI (epic #253, spike #245). Board-toolkit fixture style: throwaway plan-note
# files in a tmpdir; writeback tests point KNOWLEDGE_STORE_ROOT at a disposable
# tmpdir "store" so a real ks_write round-trip happens with ZERO touches to
# the operator's real vault, structured-output assertions via jq.
#
# Covers:
#   - validate: a valid approved plan → VALID; malformed plans → INVALID +
#     non-zero exit (draft status, duplicate slug, missing acceptance, bad
#     branch, dangling depends-on/after ref, leftover acceptance placeholder,
#     non-int gh_issue, gh_issue+split_from together, prose external gate with
#     no gate_check); a depends-on ∪ after cycle → INVALID (rule 8)
#   - toposort: a 2-level DAG over the union of depends-on + after → the right
#     level partition; a cycle → CYCLE outcome + non-zero exit
#   - writeback routes EVERY vault write through _plan_vault_write → ks_write
#     (foundation #954; no curl anywhere post-migration): a real round-trip
#     against a throwaway store root flips the sentinel and stamps sub-lines,
#     WRITTEN is emitted; a spaced plan filename round-trips with no encoding
#     needed (#364 regression, post-migration)
#   - a knowledge-store write failure (blocked store root) → WRITE_FAILED +
#     non-zero exit + stderr; NEVER silent success. Same for knowledge_store.sh
#     not being sourceable (stripped-down checkout missing the seam).
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plan.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- fixtures ----------------------------------------------------------------
# A valid, approved 2-level plan. Edges:
#   base       : (none)            → L0
#   builds-on  : depends-on base   → L1
#   follows    : after base        → L1
# So levels = [[base], [builds-on, follows]].
cat > "$TMP/valid.md" <<'EOF'
---
tags: [plan, project/foundation]
date: 2026-06-09
status: approved
---

# foundation - valid plan

## Items

- [ ] **Base change** `slug: base` — the foundation item
  - branch: `feat/base`
  - size: S
  - acceptance:
    - base works
    - tests pass

- [ ] **Builds on base** `slug: builds-on` — extends base
  - branch: `feat/builds-on`
  - size: M
  - depends-on: base
  - gh_issue: 4567
  - acceptance:
    - extension works

- [ ] **Follows base logically** `slug: follows` — sequenced after base
  - branch: `fix/follows`
  - size: S
  - after: base
  - acceptance:
    - follows correctly
EOF

# --- validate: the valid plan passes -----------------------------------------
out="$(bash "$SCRIPT" validate "$TMP/valid.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "valid plan not VALID (got: $out)"
echo "PASS: validate → VALID on a well-formed approved plan"

# --- validate: draft status is rejected (rule 1) -----------------------------
sed 's/^status: approved/status: draft/' "$TMP/valid.md" > "$TMP/draft.md"
rc=0; out="$(bash "$SCRIPT" validate "$TMP/draft.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "draft plan did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "INVALID" ] || fail "draft not INVALID (got: $out)"
jq -e '.errors | map(test("rule 1")) | any' <<<"$out" >/dev/null \
  || fail "draft INVALID but rule 1 not in errors (got: $out)"
echo "PASS: validate → INVALID + non-zero on a draft (non-approved) plan (rule 1)"

# --- validate: duplicate slug is rejected (rule 3) ---------------------------
cat > "$TMP/dupe.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **First** `slug: same` — one
  - branch: `feat/same`
  - acceptance:
    - x

- [ ] **Second** `slug: same` — two
  - branch: `feat/same`
  - acceptance:
    - y
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/dupe.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate-slug plan did not exit non-zero"
jq -e '.errors | map(test("duplicate slug")) | any' <<<"$out" >/dev/null \
  || fail "duplicate slug not flagged (got: $out)"
echo "PASS: validate → INVALID + non-zero on a duplicate slug (rule 3)"

# --- validate: missing acceptance / bad branch / dangling refs ---------------
cat > "$TMP/multi.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **No acceptance** `slug: no-acc` — missing block
  - branch: `feat/no-acc`

- [ ] **Bad branch** `slug: bad-branch` — wrong prefix
  - branch: `feature/bad-branch`
  - acceptance:
    - x

- [ ] **Dangling depends** `slug: dangling` — points nowhere
  - branch: `feat/dangling`
  - depends-on: ghost
  - after: phantom
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/multi.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "multi-error plan did not exit non-zero"
jq -e '.errors | map(test("rule 2")) | any' <<<"$out" >/dev/null || fail "missing acceptance (rule 2) not flagged (got: $out)"
jq -e '.errors | map(test("rule 4")) | any' <<<"$out" >/dev/null || fail "bad branch (rule 4) not flagged (got: $out)"
jq -e '.errors | map(test("rule 5")) | any' <<<"$out" >/dev/null || fail "dangling depends-on (rule 5) not flagged (got: $out)"
jq -e '.errors | map(test("rule 8.*phantom|after .phantom")) | any' <<<"$out" >/dev/null || fail "dangling after (rule 8) not flagged (got: $out)"
echo "PASS: validate flags missing acceptance, bad branch, dangling depends-on/after (rules 2/4/5/8)"

# --- validate: acceptance placeholder is fatal (rule 9) ----------------------
cat > "$TMP/placeholder.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Placeholder** `slug: ph` — unfinished acceptance
  - branch: `feat/ph`
  - acceptance:
    - (no acceptance criteria derivable from source — fill in during review)
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/placeholder.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 9")) | any' <<<"$out" >/dev/null \
  || fail "leftover acceptance placeholder not flagged (rule 9) (got: $out)"
echo "PASS: validate → INVALID on a leftover acceptance placeholder (rule 9)"

# --- validate: gh_issue must be a positive int (rule 7) ----------------------
cat > "$TMP/badissue.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Bad issue** `slug: bad-issue` — non-int gh_issue
  - branch: `feat/bad-issue`
  - gh_issue: abc
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/badissue.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 7")) | any' <<<"$out" >/dev/null \
  || fail "non-int gh_issue not flagged (rule 7) (got: $out)"
echo "PASS: validate → INVALID on a non-integer gh_issue (rule 7)"

# --- validate: gh_issue + split_from mutual exclusion (rule 10) --------------
cat > "$TMP/bothrefs.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Both refs** `slug: both` — gh_issue and split_from together
  - branch: `feat/both`
  - gh_issue: 100
  - split_from: #40
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/bothrefs.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 10")) | any' <<<"$out" >/dev/null \
  || fail "gh_issue+split_from not flagged (rule 10) (got: $out)"
echo "PASS: validate → INVALID when gh_issue and split_from coexist (rule 10)"

# --- validate: prose external gate without gate_check (rule 11) --------------
cat > "$TMP/gate.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/gate.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 11")) | any' <<<"$out" >/dev/null \
  || fail "prose external gate without gate_check not flagged (rule 11) (got: $out)"
# adding a gate_check clears it
cat > "$TMP/gate-ok.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - gate_check: "configs/artists.toml lists >=40 artists"
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/gate-ok.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "external gate WITH gate_check should be VALID (got: $out)"
echo "PASS: validate flags a prose external gate missing gate_check, clears it once gate_check present (rule 11)"

# --- toposort: 2-level DAG over depends-on ∪ after ----------------------------
out="$(bash "$SCRIPT" toposort "$TMP/valid.md")"
jq -e '.levels | length == 2' <<<"$out" >/dev/null || fail "expected 2 levels (got: $out)"
jq -e '.levels[0] == ["base"]' <<<"$out" >/dev/null || fail "L0 should be [base] (got: $out)"
jq -e '.levels[1] | sort == ["builds-on","follows"]' <<<"$out" >/dev/null \
  || fail "L1 should be {builds-on, follows} (got: $out)"
echo "PASS: toposort partitions a 2-level DAG over the depends-on ∪ after union"

# --- toposort: a cycle fails loud (rule 8 / CYCLE outcome) -------------------
cat > "$TMP/cycle.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **A** `slug: a` — cycles to b
  - branch: `feat/a`
  - depends-on: b
  - acceptance:
    - x

- [ ] **B** `slug: b` — cycles to a
  - branch: `feat/b`
  - after: a
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" toposort "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "cyclic toposort did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "CYCLE" ] || fail "cycle not reported as CYCLE (got: $out)"
echo "PASS: toposort → CYCLE + non-zero exit on a depends-on ∪ after cycle"
# validate catches the same cycle as rule 8
rc=0; out="$(bash "$SCRIPT" validate "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 8")) | any' <<<"$out" >/dev/null \
  || fail "validate did not flag the cycle as rule 8 (got: $out)"
echo "PASS: validate → INVALID (rule 8) on the same cycle"

# --- writeback: no REST/curl left — ks_write is the sole write path (F#954) --
# The old REST PUT transport is gone entirely post-migration (foundation #954,
# Epic "Obsidian → knowledge_store parallel-run migration" #951, Phase 2
# #948) — confirm no curl call remains anywhere in the script, and that the
# _plan_vault_write seam routes through ks_write.
grep -qE '\bcurl\b' "$SCRIPT" \
  && fail "plan.sh should contain no curl calls post-migration to ks_write (F#954)"
grep -q '_plan_vault_write' "$SCRIPT" || fail "expected the _plan_vault_write seam to still exist"
grep -q 'ks_write "\$vault_path"' "$SCRIPT" || fail "_plan_vault_write should route through ks_write"
echo "PASS: plan.sh contains no curl calls; _plan_vault_write routes through ks_write (F#954)"

# --- writeback: real ks_write round-trip against a throwaway store root ------
# Point KNOWLEDGE_STORE_ROOT at a disposable tmpdir (never the operator's real
# vault) and exercise a REAL plain-files write — no REST, no shim needed; this
# IS the transport now, so exercising it for real is more valuable than a fake.
STORE="$TMP/store"
mkdir -p "$STORE"
cp "$TMP/valid.md" "$TMP/wb.md"
out="$(KNOWLEDGE_STORE_ROOT="$STORE" KNOWLEDGE_STORE_BACKEND="plain-files" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[~]' \
  --pr 142 --pushed-sha abc123 --run-status "worker active")"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "writeback not WRITTEN (got: $out)"
[ "$(jq -r .sentinel <<<"$out")" = "[~]" ] || fail "writeback sentinel not echoed (got: $out)"
WRITTEN_FILE="$STORE/Plans/wb.md"
[ -f "$WRITTEN_FILE" ] || fail "expected ks_write to land the note at $WRITTEN_FILE"
grep -q '^- \[~\] \*\*Builds on base\*\* `slug: builds-on`' "$WRITTEN_FILE" \
  || fail "written note did not flip the builds-on sentinel to [~]"
grep -q '^  - pr: 142' "$WRITTEN_FILE" || fail "written note missing stamped pr: 142"
grep -q '^  - pushed_sha: abc123' "$WRITTEN_FILE" || fail "written note missing stamped pushed_sha"
grep -q '^  - Run-status: worker active' "$WRITTEN_FILE" || fail "written note missing Run-status stamp"
# the OTHER items must be untouched (base still [ ])
grep -q '^- \[ \] \*\*Base change\*\* `slug: base`' "$WRITTEN_FILE" \
  || fail "writeback disturbed an unrelated item's sentinel"
echo "PASS: writeback flips the target sentinel, stamps pr/pushed_sha/Run-status, leaves others untouched (real ks_write round-trip, → WRITTEN)"

# --- writeback: plan filename with spaces round-trips through ks_write (#364) --
# Every real plan filename has spaces ('Plans/<date> <project> - <title>.md').
# The old REST transport needed percent-encoding to survive the PUT (#364);
# ks_write treats the doc-id as a plain filesystem-relative path, so a spaced
# name just works — prove it still lands at the right path, sentinel flipped.
mkdir -p "$TMP/Plans"
cp "$TMP/valid.md" "$TMP/Plans/2026-06-11 stagefind - spaces in name.md"
out="$(KNOWLEDGE_STORE_ROOT="$STORE" KNOWLEDGE_STORE_BACKEND="plain-files" \
  bash "$SCRIPT" writeback "$TMP/Plans/2026-06-11 stagefind - spaces in name.md" \
  --slug base --sentinel '[x]')"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "spaced-filename writeback not WRITTEN (got: $out)"
SPACED_FILE="$STORE/Plans/2026-06-11 stagefind - spaces in name.md"
[ -f "$SPACED_FILE" ] || fail "expected a spaced plan filename to land at '$SPACED_FILE'"
grep -q '^- \[x\] \*\*Base change\*\* `slug: base`' "$SPACED_FILE" \
  || fail "spaced-filename writeback did not flip the base sentinel"
echo "PASS: writeback round-trips a spaced plan filename through ks_write with no encoding needed (#364 regression, post-migration)"

# --- writeback: a knowledge-store write failure → WRITE_FAILED + non-zero + stderr ---
# Point KNOWLEDGE_STORE_ROOT at a path that cannot be mkdir'd into (a regular
# file standing where a directory must go), so the plain-files backend's
# mkdir -p fails — the local-filesystem analog of the old "unreachable REST"
# failure. Must still fail loud, never silent.
BLOCKED="$TMP/blocked-root"
: > "$BLOCKED"   # a FILE, not a directory
rc=0
out="$(KNOWLEDGE_STORE_ROOT="$BLOCKED" KNOWLEDGE_STORE_BACKEND="plain-files" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[m]' 2>"$TMP/err")" || rc=$?
[ "$rc" -ne 0 ] || fail "blocked store-root writeback did NOT exit non-zero (silent success — the forbidden failure)"
[ "$(jq -r .outcome <<<"$out")" = "WRITE_FAILED" ] || fail "blocked store-root not WRITE_FAILED (got: $out)"
[ -s "$TMP/err" ] || fail "no fail-loud stderr message on a knowledge-store write failure"
echo "PASS: a knowledge-store write failure → WRITE_FAILED + non-zero exit + stderr (never silent success)"

# --- writeback: knowledge_store.sh not sourceable → fail loud ----------------
# Copy plan.sh to an isolated location with NO sibling lib/knowledge_store.sh
# (PLAN_LIB_DIR is BASH_SOURCE-relative, so this makes it unresolvable) — the
# local analog of the old "missing REST key-file" precondition failure (a
# stripped-down checkout missing the seam must still fail loud, not silently).
mkdir -p "$TMP/isolated/build" "$TMP/isolated/lib"   # lib/ exists but has no knowledge_store.sh
cp "$SCRIPT" "$TMP/isolated/build/plan.sh"
rc=0
out="$(bash "$TMP/isolated/build/plan.sh" writeback "$TMP/wb.md" --slug base --sentinel '[x]' 2>"$TMP/err2")" || rc=$?
[ "$rc" -ne 0 ] || fail "writeback with no knowledge_store.sh available did not exit non-zero"
grep -qi 'not sourceable' "$TMP/err2" || fail "no fail-loud stderr when knowledge_store.sh is missing (got: $(cat "$TMP/err2"))"
echo "PASS: knowledge_store.sh not sourceable → fail loud (non-zero + stderr)"

# --- error: bad args → structured ERROR + non-zero ----------------------------
rc=0; out="$(bash "$SCRIPT" validate "$TMP/nonexistent.md" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "validate on missing file not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug base 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback without --sentinel not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug ghost --sentinel '[x]' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback on unknown slug not structured ERROR (got: $out)"
echo "PASS: bad args (missing file, no --sentinel, unknown slug) → structured ERROR + non-zero"
