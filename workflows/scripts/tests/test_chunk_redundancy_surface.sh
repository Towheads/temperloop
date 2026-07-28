#!/usr/bin/env bash
#
# test_chunk_redundancy_surface.sh — fixture + real-tree tests for
# workflows/scripts/chunk-redundancy-surface.sh (temperloop#854, half (a) of
# the P9 semantic-redundancy probe).
#
# Covers:
#   1. real-tree happy path — every manifest row produces >=1 chunk, every
#      stdout line is a well-formed, complete JSON object (no truncation).
#   2. determinism — two runs on the same tree are byte-identical.
#   3. synthetic full-unit fixture — the rule-sized boundary contract:
#      headings never become chunks but set the section breadcrumb;
#      consecutive top-level bullets with NO blank line between them still
#      split; an INDENTED sub-bullet does NOT split (swept into its parent
#      chunk); a numbered list splits per item; a fenced code block
#      containing heading-/list-shaped lines is never split internally;
#      blank-line-separated paragraphs split.
#   4. synthetic frontmatter:description fixture — the whole description
#      value is one atomic chunk, section is null.
#   5. error paths — missing manifest, missing referenced file, malformed
#      row, and (env permitting) jq absent from PATH.
#
# Usage: bash workflows/scripts/tests/test_chunk_redundancy_surface.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/chunk-redundancy-surface.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else fail_test "$name" "expected '$want', got '$got'"; fi
}
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-chunk-redundancy-surface.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# jsonl_field <jsonl-line> <field> — pull one top-level field's raw jq value
# (works for scalars: strings unquoted via -r, numbers verbatim).
jf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ── 1. real-tree happy path ──────────────────────────────────────────────────
echo "--- 1. real-tree happy path ---"
out="$(bash "$SCRIPT" 2>/tmp/crs_stderr_real)"; rc=$?
assert_rc "$rc" 0 "real tree exits 0"

manifest_rows="$(grep -vc '^[[:space:]]*#\|^[[:space:]]*$' "$REPO/workflows/scripts/config/contributor-manifest.tsv")"
line_count="$(printf '%s\n' "$out" | grep -c .)"
if [ "$line_count" -ge "$manifest_rows" ]; then
  ok "at least one chunk per manifest row ($line_count chunks >= $manifest_rows rows)"
else
  fail_test "at least one chunk per manifest row" "got $line_count chunks for $manifest_rows rows"
fi

# Every stdout line must be one COMPLETE, well-formed JSON object — proves no
# embedded raw newline broke a record across physical lines (the exact bug
# class this stream's escaping must prevent).
malformed=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s' "$line" | jq -e 'has("id") and has("path") and has("text") and has("chunk_index")' >/dev/null 2>&1 || malformed=$((malformed + 1))
done <<<"$out"
assert_eq "$malformed" "0" "every stdout line is a complete, well-formed JSON chunk record"

assert_has "$(cat /tmp/crs_stderr_real)" "row(s)" "stderr carries a one-line summary, never mixed into stdout"

# ── 2. determinism ────────────────────────────────────────────────────────────
echo "--- 2. determinism ---"
out2="$(bash "$SCRIPT" 2>/dev/null)"
assert_eq "$out2" "$out" "two runs on the same tree are byte-identical"

# ── 3. synthetic full-unit fixture: the rule-sized boundary contract ────────
echo "--- 3. synthetic full-unit boundary contract ---"
FIXROOT="$TMP/fixture-repo"
mkdir -p "$FIXROOT/workflows/scripts/config"
git -C "$FIXROOT" init -q 2>/dev/null || { mkdir -p "$FIXROOT/.git"; }

cat > "$FIXROOT/RULES.md" <<'EOF'
# Top doc

Intro paragraph, a single rule stated on its own with no list marker at
all.

## Section A

- First bullet, no blank line follows it.
- Second bullet immediately after — still its own chunk.
  - An indented sub-bullet: part of the second bullet's own chunk, not a
    boundary of its own.
- Third top-level bullet after the sub-bullet.

## Section B

1. First numbered item.
2. Second numbered item, right after with no blank line.

```
# this looks like a heading but is INSIDE a fence
- so does this bullet
```

Closing paragraph after the fence, in its own chunk.
EOF

cat > "$FIXROOT/workflows/scripts/config/contributor-manifest.tsv" <<'EOF'
RULES.md	full	kernel-pointer	harness-auto
EOF

fixout="$(REDUNDANCY_CHUNK_ROOT="$FIXROOT" bash "$SCRIPT" 2>/tmp/crs_stderr_fix)"; rc=$?
assert_rc "$rc" 0 "synthetic fixture run exits 0"

fix_chunk_count="$(printf '%s\n' "$fixout" | grep -c .)"
# Expected chunks, in order:
#   1. Intro paragraph                              (Section: # Top doc)
#   2. First bullet                                  (## Section A)
#   3. Second bullet (sub-bullet swept in)            (## Section A)
#   4. Third top-level bullet                         (## Section A)
#   5. First numbered item                            (## Section B)
#   6. Second numbered item                           (## Section B)
#   7. Fenced code block (opaque, one chunk)           (## Section B)
#   8. Closing paragraph                               (## Section B)
assert_eq "$fix_chunk_count" "8" "synthetic fixture yields the expected 8 rule-sized chunks"

get_chunk() { printf '%s\n' "$fixout" | sed -n "${1}p"; }

c1="$(get_chunk 1)"; c2="$(get_chunk 2)"; c3="$(get_chunk 3)"; c4="$(get_chunk 4)"
c5="$(get_chunk 5)"; c6="$(get_chunk 6)"; c7="$(get_chunk 7)"; c8="$(get_chunk 8)"

assert_has "$(jf "$c1" .text)" "Intro paragraph" "chunk 1 is the intro paragraph"
assert_eq "$(jf "$c1" .section)" "# Top doc" "chunk 1's section breadcrumb is the H1"

assert_has "$(jf "$c2" .text)" "First bullet" "chunk 2 is the first bullet"
assert_eq "$(jf "$c2" .section)" "# Top doc > ## Section A" "chunk 2's section breadcrumb nests H1 > H2"

assert_has "$(jf "$c3" .text)" "Second bullet" "chunk 3 is the second bullet"
assert_has "$(jf "$c3" .text)" "indented sub-bullet" "chunk 3 SWEEPS its indented sub-bullet in (not a separate chunk)"

assert_has "$(jf "$c4" .text)" "Third top-level bullet" "chunk 4 is the third top-level bullet (split after the sub-bullet ended)"

assert_has "$(jf "$c5" .text)" "First numbered item" "chunk 5 is the first numbered item"
assert_eq "$(jf "$c5" .section)" "# Top doc > ## Section B" "chunk 5's section breadcrumb updates to Section B"
assert_has "$(jf "$c6" .text)" "Second numbered item" "chunk 6 is the second numbered item (split with no blank line)"

assert_has "$(jf "$c7" .text)" "this looks like a heading but is INSIDE a fence" "chunk 7 is the fenced code block, contents preserved"
assert_has "$(jf "$c7" .text)" "so does this bullet" "chunk 7's fence-interior bullet-shaped line stayed INSIDE the same chunk (not split)"

assert_has "$(jf "$c8" .text)" "Closing paragraph" "chunk 8 is the closing paragraph after the fence"

# chunk_count field is internally consistent (every row of this fixture
# reports the same total, matching the number of chunks actually emitted).
cc_field="$(jf "$c1" .chunk_count)"
assert_eq "$cc_field" "8" "chunk_count field matches the real number of chunks emitted for the row"

# ── 4. synthetic frontmatter:description fixture ────────────────────────────
echo "--- 4. synthetic frontmatter:description fixture ---"
FIXROOT2="$TMP/fixture-repo-2"
mkdir -p "$FIXROOT2/workflows/scripts/config" "$FIXROOT2/claude/commands"
mkdir -p "$FIXROOT2/.git"

cat > "$FIXROOT2/claude/commands/demo.md" <<'EOF'
---
description: A one-line self-description with an embedded, "quoted" phrase and an apostrophe's mark.
---

# demo

Body text, never read by the frontmatter:description unit.
EOF

cat > "$FIXROOT2/workflows/scripts/config/contributor-manifest.tsv" <<'EOF'
claude/commands/demo.md	frontmatter:description	command-listing	harness-auto
EOF

fixout2="$(REDUNDANCY_CHUNK_ROOT="$FIXROOT2" bash "$SCRIPT" 2>/dev/null)"; rc=$?
assert_rc "$rc" 0 "frontmatter fixture run exits 0"
fix2_count="$(printf '%s\n' "$fixout2" | grep -c .)"
assert_eq "$fix2_count" "1" "a frontmatter:description row yields exactly one atomic chunk"
assert_eq "$(jf "$fixout2" .section)" "null" "a frontmatter:description chunk has a null section (no heading context applies)"
assert_has "$(jf "$fixout2" .text)" "quoted" "frontmatter chunk text preserves an embedded double-quote phrase, correctly escaped"
assert_has "$(jf "$fixout2" .text)" "apostrophe's mark" "frontmatter chunk text preserves an embedded apostrophe"
assert_eq "$(jf "$fixout2" .unit)" "frontmatter:description" "frontmatter chunk reports its own unit"

# ── 5. error paths ────────────────────────────────────────────────────────────
echo "--- 5. error paths ---"

# 5a. missing manifest
NOMANI="$TMP/no-manifest"
mkdir -p "$NOMANI/.git"
out="$(REDUNDANCY_CHUNK_ROOT="$NOMANI" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "missing manifest exits 1"
assert_has "$out" "contributor manifest not found" "missing manifest named"

# 5b. manifest referencing a path that does not exist
NOFILE="$TMP/no-file"
mkdir -p "$NOFILE/workflows/scripts/config" "$NOFILE/.git"
printf 'GONE.md\tfull\tkernel-pointer\tharness-auto\n' > "$NOFILE/workflows/scripts/config/contributor-manifest.tsv"
out="$(REDUNDANCY_CHUNK_ROOT="$NOFILE" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "manifest row pointing at a missing file exits 1"
assert_has "$out" "does not exist" "missing referenced file named"

# 5c. malformed row (missing fields)
MALFORMED="$TMP/malformed"
mkdir -p "$MALFORMED/workflows/scripts/config" "$MALFORMED/.git"
printf 'CLAUDE.md\tfull\n' > "$MALFORMED/workflows/scripts/config/contributor-manifest.tsv"
out="$(REDUNDANCY_CHUNK_ROOT="$MALFORMED" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "malformed (2-field) row exits 1"
assert_has "$out" "malformed contributor-manifest row" "malformed row named"

# 5d. jq absent from PATH — build a minimal PATH with every OTHER external
# command this script needs, but no jq, so the script's own dependency
# check fires rather than a generic "command not found" further down.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
for tool in bash sh mktemp tr wc awk grep sha256sum shasum rm basename dirname cat sed mkdir; do
  p="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$p" "$FAKEBIN/$tool"
done
if [ -x "$FAKEBIN/bash" ]; then
  out="$(PATH="$FAKEBIN" bash "$SCRIPT" 2>&1)"; rc=$?
  assert_rc "$rc" 1 "jq absent from PATH exits 1"
  assert_has "$out" "jq not found" "jq-absent case is named, not a generic failure"
else
  echo "  skip  jq-absent-from-PATH case (could not stage a minimal PATH on this host)"
fi

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_chunk_redundancy_surface: FAIL"
  exit 1
fi
echo "test_chunk_redundancy_surface: OK"
