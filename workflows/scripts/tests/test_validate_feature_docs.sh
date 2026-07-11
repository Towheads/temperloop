#!/usr/bin/env bash
#
# test_validate_feature_docs.sh — fixture tests for
# workflows/scripts/validate-feature-docs.sh (temperloop#132).
#
# Each case builds a synthetic git repo under mktemp (files staged with
# `git add` — the coverage walk reads the index via `git ls-files`, no commit
# needed) and points the validator at it via the FEATURE_DOCS_ROOT /
# FEATURE_MANIFEST_FILE / FEATURE_EXEMPT_FILE / FEATURE_DOCS_DIR seams.
# Covers the green path, every failure class the contract names, the
# inert-pre-claim guarantee (acceptance 5), collect-all-failures, and the
# parse errors. Zero network.
#
# Usage: bash workflows/scripts/tests/test_validate_feature_docs.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-feature-docs.sh"

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

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# make_fixture <name> — fresh git repo with two claimed source files and the
# default registries: slugs alpha (documented) and beta (exempt, no doc).
# Callers then mutate files/registries per case.
make_fixture() {
  local name="$1" root="$TMP/$1"
  mkdir -p "$root/src" "$root/docs/features"
  git init -q "$root"
  printf 'a\n' > "$root/src/a.sh"
  printf 'b\n' > "$root/src/b.sh"
  cat > "$root/docs/features/feature-manifest.txt" <<'EOF'
# fixture manifest
none docs/features/*
alpha src/a.sh
beta src/b.sh
EOF
  cat > "$root/docs/features/backfill-exempt.txt" <<'EOF'
# fixture ratchet
beta
EOF
  write_doc "$root" alpha
  git -C "$root" add -A
  printf '%s' "$root"
}

# write_doc <root> <slug> — a well-formed 5-section doc for <slug>.
write_doc() {
  local root="$1" slug="$2"
  cat > "$root/docs/features/$slug.md" <<EOF
---
title: $slug
slug: $slug
---

## Problem

Words about the problem.

## How it works

Words about the mechanism.

## Integration

None.

## Resource impact

None.

## Telemetry

None.
EOF
}

# run_validator <root> — run against a fixture; stdout+stderr in $out, rc in $rc.
out=""
rc=0
run_validator() {
  local root="$1"
  rc=0
  out="$(FEATURE_DOCS_ROOT="$root" bash "$SCRIPT" 2>&1)" || rc=$?
}

# ── 1. green path ─────────────────────────────────────────────────────────────
echo "--- 1. green: claimed paths, doc'd alpha, exempt beta ---"
ROOT="$(make_fixture green)"
run_validator "$ROOT"
assert_rc "$rc" 0 "green fixture exits 0"
assert_has "$out" "validate-feature-docs: OK" "green fixture says OK"
assert_has "$out" "2 feature slug(s), 1 doc(s), 1 exemption(s)" "green summary counts"

# ── 2. unclaimed tracked path ────────────────────────────────────────────────
echo "--- 2. unclaimed tracked path ---"
ROOT="$(make_fixture unclaimed)"
printf 'c\n' > "$ROOT/src/unclaimed.sh"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "unclaimed path exits 1"
assert_has "$out" "UNCLAIMED  src/unclaimed.sh" "unclaimed path named"

# ── 3. missing doc for a non-exempt slug ─────────────────────────────────────
echo "--- 3. missing doc, non-exempt slug ---"
ROOT="$(make_fixture missingdoc)"
: > "$ROOT/docs/features/backfill-exempt.txt"   # un-exempt beta
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "missing doc exits 1"
assert_has "$out" "MISSING-DOC  beta" "missing doc names the slug"

# ── 3b. missing exempt file == empty ratchet (end state), not an error ───────
echo "--- 3b. exempt file absent entirely ---"
ROOT="$(make_fixture noexemptfile)"
rm "$ROOT/docs/features/backfill-exempt.txt"
write_doc "$ROOT" beta
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 0 "absent exempt file with all docs present exits 0"

# ── 4. missing required section ──────────────────────────────────────────────
echo "--- 4. missing required section ---"
ROOT="$(make_fixture missingsection)"
# drop '## Telemetry' (and its body) from alpha.md
sed_out="$(awk '/^## Telemetry$/{drop=1} !drop{print}' "$ROOT/docs/features/alpha.md")"
printf '%s\n' "$sed_out" > "$ROOT/docs/features/alpha.md"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "missing section exits 1"
assert_has "$out" "MISSING-SECTION  alpha.md — required section '## Telemetry' absent" "missing section named"

# ── 5. empty required section ────────────────────────────────────────────────
echo "--- 5. empty required section ---"
ROOT="$(make_fixture emptysection)"
# empty out '## Resource impact' (heading kept, body removed)
awk '
  /^## Resource impact$/ { print; skip=1; next }
  skip && /^#/ { skip=0 }
  !skip { print }
' "$ROOT/docs/features/alpha.md" > "$ROOT/docs/features/alpha.md.new"
mv "$ROOT/docs/features/alpha.md.new" "$ROOT/docs/features/alpha.md"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "empty section exits 1"
assert_has "$out" "EMPTY-SECTION  alpha.md — required section '## Resource impact'" "empty section named"

# ── 6. orphan doc ────────────────────────────────────────────────────────────
echo "--- 6. orphan doc (stem not a manifest slug) ---"
ROOT="$(make_fixture orphan)"
write_doc "$ROOT" gamma
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "orphan doc exits 1"
assert_has "$out" "ORPHAN-DOC  gamma.md" "orphan doc named"

# ── 7. frontmatter slug != filename stem ─────────────────────────────────────
echo "--- 7. frontmatter slug mismatch ---"
ROOT="$(make_fixture slugmismatch)"
perl_free_edit="$(awk '{ if ($0 == "slug: alpha") print "slug: omega"; else print }' "$ROOT/docs/features/alpha.md")"
printf '%s\n' "$perl_free_edit" > "$ROOT/docs/features/alpha.md"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "slug mismatch exits 1"
assert_has "$out" "SLUG-MISMATCH  alpha.md — frontmatter 'slug: omega' != filename stem 'alpha'" "slug mismatch named"

# ── 7b. frontmatter slug absent ──────────────────────────────────────────────
echo "--- 7b. frontmatter slug line absent ---"
ROOT="$(make_fixture slugabsent)"
noslug="$(grep -v '^slug: alpha$' "$ROOT/docs/features/alpha.md")"
printf '%s\n' "$noslug" > "$ROOT/docs/features/alpha.md"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "absent slug line exits 1"
assert_has "$out" "SLUG-MISMATCH  alpha.md — no single-line 'slug:' in frontmatter" "absent slug line named"

# ── 8. stale exemption ───────────────────────────────────────────────────────
echo "--- 8. stale exemption (slug not in manifest) ---"
ROOT="$(make_fixture staleexempt)"
printf 'ghost\n' >> "$ROOT/docs/features/backfill-exempt.txt"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "stale exemption exits 1"
assert_has "$out" "STALE-EXEMPT  ghost" "stale exemption named"

# ── 9. exempt-but-documented ─────────────────────────────────────────────────
echo "--- 9. exempt-but-documented (ratchet line kept after doc landed) ---"
ROOT="$(make_fixture exemptdoc)"
write_doc "$ROOT" beta          # beta stays in backfill-exempt.txt
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "exempt-but-documented exits 1"
assert_has "$out" "EXEMPT-BUT-DOCUMENTED  beta" "exempt-but-documented named"

# ── 10. inert pre-claim (acceptance 5) ───────────────────────────────────────
echo "--- 10. claim for a not-yet-tracked path is legal and inert ---"
ROOT="$(make_fixture preclaim)"
cat >> "$ROOT/docs/features/feature-manifest.txt" <<'EOF'
none docs/architecture.md
none future/dir/*
alpha src/not-written-yet.sh
EOF
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 0 "pre-claimed untracked paths exit 0"
assert_has "$out" "validate-feature-docs: OK" "pre-claim fixture says OK"

# ── 10b. longest-match override wins over a broad claim ─────────────────────
echo "--- 10b. longest-match-wins override ---"
ROOT="$(make_fixture longestmatch)"
# beta's file also matched by a broad `none src/*`; the longer per-file claims
# must keep both slugs live (beta stays a real slug -> still needs exemption).
cat > "$ROOT/docs/features/feature-manifest.txt" <<'EOF'
none docs/features/*
none src/*
alpha src/a.sh
beta src/b.sh
EOF
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 0 "override fixture exits 0"
assert_has "$out" "2 feature slug(s)" "both specific slugs still counted"

# ── 11. collect-all-failures: one run surfaces every class ───────────────────
echo "--- 11. collect-all-failures ---"
ROOT="$(make_fixture collectall)"
printf 'c\n' > "$ROOT/src/unclaimed.sh"          # UNCLAIMED
write_doc "$ROOT" beta                            # EXEMPT-BUT-DOCUMENTED
write_doc "$ROOT" gamma                           # ORPHAN-DOC
printf 'ghost\n' >> "$ROOT/docs/features/backfill-exempt.txt"  # STALE-EXEMPT
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "multi-failure fixture exits 1"
assert_has "$out" "UNCLAIMED  src/unclaimed.sh" "collect-all: unclaimed present"
assert_has "$out" "EXEMPT-BUT-DOCUMENTED  beta" "collect-all: exempt-but-documented present"
assert_has "$out" "ORPHAN-DOC  gamma.md" "collect-all: orphan present"
assert_has "$out" "STALE-EXEMPT  ghost" "collect-all: stale exemption present"
assert_has "$out" "failures: 4" "collect-all: all four counted"

# ── 12. parse errors ─────────────────────────────────────────────────────────
echo "--- 12. malformed manifest / exempt lines ---"
ROOT="$(make_fixture badmanifest)"
printf 'slug-with-no-glob\n' >> "$ROOT/docs/features/feature-manifest.txt"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "malformed manifest line exits 1"
assert_has "$out" "malformed manifest line" "malformed manifest line named"

ROOT="$(make_fixture badslug)"
printf 'Bad_Slug src/a.sh\n' >> "$ROOT/docs/features/feature-manifest.txt"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "bad slug charset exits 1"
assert_has "$out" "bad slug 'Bad_Slug'" "bad slug named"

ROOT="$(make_fixture badexempt)"
printf 'Not A Slug\n' >> "$ROOT/docs/features/backfill-exempt.txt"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "bad exempt slug exits 1"
assert_has "$out" "bad exempt slug" "bad exempt slug named"

ROOT="$(make_fixture nomanifest)"
rm "$ROOT/docs/features/feature-manifest.txt"
git -C "$ROOT" add -A
run_validator "$ROOT"
assert_rc "$rc" 1 "missing manifest exits 1"
assert_has "$out" "manifest not found" "missing manifest named"

# ── 13. real-tree invariants this item ships (seed sanity) ───────────────────
echo "--- 13. seeded registries in this repo ---"
run_validator "$REPO"   # defaults resolve to the real registries
assert_rc "$rc" 0 "real tree is green with the seeded ratchet"
assert_lacks "$out" "UNCLAIMED" "real tree has no unclaimed path"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_validate_feature_docs: FAIL"
  exit 1
fi
echo "test_validate_feature_docs: OK"
