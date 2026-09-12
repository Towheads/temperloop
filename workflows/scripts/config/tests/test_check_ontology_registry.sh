#!/usr/bin/env bash
#
# Fixture tests for check-ontology-registry.sh (ADR 0032, epic
# temperloop#1910 L0-b). The live gate only ever exercises the GREEN arm
# against this repo's own tree; every RED arm is proven here, deterministically,
# through the checker's fixture seams (ONTOLOGY_* env overrides) so no case
# depends on the real tree except the last.
#
# Coverage:
#   1.  GREEN  a clean fixture tree (listed labels, listed sentinels, docs
#              pointing at the registry) passes.
#   2.  RED    one unlisted `fnd:` label AND one unlisted sentinel in the tree
#              — both named with their path:line.
#   3.  GREEN  a label under the personal prefix (`x-`) is never flagged,
#              whether the prefix is on the field or on the value.
#   4.  GREEN  a grandfathered token passes; 4b RED a grandfather row whose
#              token is gone from the tree is GRANDFATHER-STALE; 4c RED a
#              grandfather row whose token the registry lists is STALE too.
#   5.  RATCHET (scratch git repo): 5a adding an allowlist row absent at the
#              base ref is ALLOWLIST-GREW (RED); 5b removing a row passes
#              (GREEN); 5c an explicit unresolvable base ref is CANNOT
#              EVALUATE (exit 2).
#   6.  RED    a contract doc with no pointer is DOC-CITATION-MISSING; 6b a
#              doc tabling a registry token is DOC-RESTATES; 6c a doc
#              restating the `- [<c>] <title>` sentinel grammar is DOC-RESTATES.
#   7.  RED    route drift in both directions (registry lists a route the
#              resolver does not emit; resolver emits one the registry lacks).
#   8.  RED    malformed registry rows: a 3-field row, an unknown axis, a
#              duplicate (axis, token), a required axis with no row.
#   9.  DEGENERATE (the check-surface-registry.tsv anchors): an ABSENT,
#              UNREADABLE, or EMPTY registry never exits 0.
#  10.  GREEN  the real tree — the live gate's own invocation.
#
# FIXTURE-TOKEN DISCIPLINE: this file is itself part of the tracked tree the
# live gate scans, so no unlisted token may appear here LITERALLY — every
# deliberately-bad token is assembled at run time (`"$F_STATUS:bogus"`,
# `printf '[%s]' '!'`), never written out.
#
# Kept bash-3.2-portable (no mapfile, no associative arrays).

# shellcheck disable=SC2016  # backticks inside printf formats are literal fixture text
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$CONFIG_DIR/../../.." && pwd)"
CHECKER="$CONFIG_DIR/check-ontology-registry.sh"
REAL_REGISTRY="$CONFIG_DIR/ontology-registry.tsv"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'PASS: %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ontology-registry-test-XXXXXX")"
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

gitc() { git -c user.name="Ontology Test" -c user.email="ontology-test@example.com" -c commit.gpgsign=false "$@"; }

# Assembled-at-runtime tokens (see FIXTURE-TOKEN DISCIPLINE above).
F_STATUS="fnd:status"
BAD_LABEL="$F_STATUS:bogus"
BAD_SENT="$(printf '[%s]' '!')"

# A minimal resolver fixture carrying the same route block grammar as
# workflows/scripts/build/issue-state.sh — split across lines as the real one is.
write_resolver() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
USAGE=<<USAGE_EOF
    "route": "fresh|adopt|question-first|claimed-elsewhere|already-done|
              ambiguous|not-an-issue|not-found|probe-failed",
USAGE_EOF
EOF
}

# make_tree <dir> — a clean fixture tree: one doc with the pointer, one file
# with listed labels and sentinels, and its tracked-path list.
make_tree() {
  local d="$1"
  mkdir -p "$d/docs" "$d/src"
  cat >"$d/docs/contract.md" <<'EOF'
# A contract doc

The vocabulary is tabled once in `workflows/scripts/config/ontology-registry.tsv`.

| Function | Behaviour |
|---|---|
| `board_resolve` | not a registry token, never flagged |
EOF
  {
    printf 'labels: %s:backlog %s:ready %s:in-progress fnd:component:ingest fnd:host/session:mini:abcd1234 fnd:seq:3 %s:* fnd:<field>:*\n' "$F_STATUS" "$F_STATUS" "$F_STATUS" "$F_STATUS"
    printf -- '- [ ] untouched\n- [~] active\n- [m] parked\n- [>] flying\n- [x] merged\n- [v] verdict\n- [-] skipped\n'
    # A regex class and an array index are NOT sentinel grammar (neither a
    # list checkbox nor a backtick-quoted single char) and must never be scanned.
    printf 'prose about `[m]` and `[?]`; a regex class [^]] and $arr[0] are not sentinels\n'
  } >"$d/src/tokens.md"
  printf 'docs/contract.md\nsrc/tokens.md\n' >"$d/tracked.txt"
  write_resolver "$d/issue-state.sh"
  printf '# empty allowlist\n' >"$d/allow.tsv"
}

# run_checker <tree> [registry] [allowlist] [docs] [base-ref]
run_checker() {
  local tree="$1" registry="${2:-$REAL_REGISTRY}" allow="${3:-$1/allow.tsv}" docs="${4-docs/contract.md}" base="${5:-}"
  env \
    ONTOLOGY_REGISTRY_FILE="$registry" \
    ONTOLOGY_ALLOWLIST_FILE="$allow" \
    ONTOLOGY_ROOT="$tree" \
    ONTOLOGY_TRACKED_FILE="$tree/tracked.txt" \
    ONTOLOGY_ISSUE_STATE_SH="$tree/issue-state.sh" \
    ONTOLOGY_CONTRACT_DOCS="$docs" \
    ONTOLOGY_ALLOWLIST_BASE_REF="$base" \
    bash "$CHECKER"
}

# --- 1. GREEN: clean fixture tree ----------------------------------------------
T="$WORK/t1"; make_tree "$T"
out="$(run_checker "$T" 2>&1)" || fail "1: clean fixture tree should pass:
$out"
case "$out" in
  *"[ok]"*"route alphabet equals issue-state.sh"*) ;;
  *) fail "1: expected the [ok] summary line, got:
$out" ;;
esac
ok "1 clean fixture tree passes (GREEN)"

# --- 2. RED: one unlisted label + one unlisted sentinel, both named ------------
T="$WORK/t2"; make_tree "$T"
printf 'stray %s here\n- %s a stray sentinel\n' "$BAD_LABEL" "$BAD_SENT" >"$T/src/stray.md"
printf 'src/stray.md\n' >>"$T/tracked.txt"
out="$(run_checker "$T" 2>&1)" && fail "2: unlisted label + sentinel should fail:
$out"
case "$out" in
  *"UNLISTED-LABEL  $BAD_LABEL at src/stray.md:1"*) ;;
  *) fail "2: expected UNLISTED-LABEL naming $BAD_LABEL at src/stray.md:1, got:
$out" ;;
esac
case "$out" in
  *"UNLISTED-SENTINEL  $BAD_SENT at src/stray.md:2"*) ;;
  *) fail "2: expected UNLISTED-SENTINEL naming $BAD_SENT at src/stray.md:2, got:
$out" ;;
esac
ok "2 an unlisted label and an unlisted sentinel are both RED, named with path:line"

# --- 3. GREEN: the personal prefix is never flagged ---------------------------
T="$WORK/t3"; make_tree "$T"
printf 'mine: fnd:x-mine:anything and %s:x-tmp and fnd:component:x-try\n' "$F_STATUS" >"$T/src/personal.md"
printf 'src/personal.md\n' >>"$T/tracked.txt"
out="$(run_checker "$T" 2>&1)" || fail "3: personal-prefix labels must never be flagged:
$out"
case "$out" in
  *"3 personal-prefix exempt"*) ;;
  *) fail "3: expected 3 exempt hits in the summary, got:
$out" ;;
esac
ok "3 a label under the personal prefix x- is never flagged, on the field or the value (GREEN)"

# --- 4. grandfather allowlist ----------------------------------------------------
T="$WORK/t4"; make_tree "$T"
printf 'legacy %s\n' "$BAD_LABEL" >"$T/src/legacy.md"
printf 'src/legacy.md\n' >>"$T/tracked.txt"
printf '%s\tlegacy fixture, tracked debt\n' "$BAD_LABEL" >"$T/allow.tsv"
out="$(run_checker "$T" 2>&1)" || fail "4: a grandfathered token should pass:
$out"
case "$out" in *"1 grandfathered"*) ;; *) fail "4: expected '1 grandfathered' in the summary, got:
$out" ;; esac
ok "4 a grandfathered token passes (GREEN)"

rm -f "$T/src/legacy.md"
printf 'docs/contract.md\nsrc/tokens.md\n' >"$T/tracked.txt"
out="$(run_checker "$T" 2>&1)" && fail "4b: a grandfather row for a token gone from the tree should fail:
$out"
case "$out" in *"GRANDFATHER-STALE  $BAD_LABEL is allowlisted but no longer appears"*) ;; *) fail "4b: expected GRANDFATHER-STALE (gone), got:
$out" ;; esac
ok "4b a grandfather row whose token left the tree is GRANDFATHER-STALE (RED)"

printf '%s:ready\tpromoted already\n' "$F_STATUS" >"$T/allow.tsv"
out="$(run_checker "$T" 2>&1)" && fail "4c: a grandfather row the registry lists should fail:
$out"
case "$out" in *"GRANDFATHER-STALE  $F_STATUS:ready is allowlisted AND registered"*) ;; *) fail "4c: expected GRANDFATHER-STALE (registered), got:
$out" ;; esac
ok "4c a grandfather row the registry already lists is GRANDFATHER-STALE (RED)"

# --- 5. ratchet: the allowlist may only shrink (scratch git repo) --------------
G="$WORK/t5"; make_tree "$G"
BAD2="$F_STATUS:legacy2"
printf 'legacy %s and %s\n' "$BAD_LABEL" "$BAD2" >"$G/src/legacy.md"
printf 'src/legacy.md\n' >>"$G/tracked.txt"
printf '%s\told fixture\n' "$BAD_LABEL" >"$G/allow.tsv"
gitc -C "$G" init -q >/dev/null 2>&1 || fail "5: git init failed"
gitc -C "$G" add -A >/dev/null 2>&1
gitc -C "$G" commit -q -m base >/dev/null 2>&1 || fail "5: base commit failed"
BASE="$(git -C "$G" rev-parse HEAD)"
# 5a: GROW — add a second row absent at the base ref.
printf '%s\tnewly discovered, sneaking in\n' "$BAD2" >>"$G/allow.tsv"
out="$(run_checker "$G" "$REAL_REGISTRY" "$G/allow.tsv" "docs/contract.md" "$BASE" 2>&1)" && fail "5a: adding an allowlist row should fail the ratchet:
$out"
case "$out" in *"ALLOWLIST-GREW  $BAD2"*"allowlist ratchet: checked against $BASE"*|*"allowlist ratchet: checked against $BASE"*"ALLOWLIST-GREW  $BAD2"*) ;; *) fail "5a: expected ALLOWLIST-GREW naming $BAD2 plus the ratchet verdict line, got:
$out" ;; esac
ok "5a adding an allowlist row absent at the base ref is ALLOWLIST-GREW (RED)"
# 5b: SHRINK — drop every row, and the tree no longer carries the tokens.
printf '# emptied\n' >"$G/allow.tsv"
printf 'nothing legacy here\n' >"$G/src/legacy.md"
out="$(run_checker "$G" "$REAL_REGISTRY" "$G/allow.tsv" "docs/contract.md" "$BASE" 2>&1)" || fail "5b: removing allowlist rows should pass the ratchet:
$out"
case "$out" in *"allowlist ratchet: checked against $BASE"*) ;; *) fail "5b: expected the ratchet verdict line, got:
$out" ;; esac
ok "5b removing an allowlist row passes — the ratchet only shrinks (GREEN)"
# 5c: an EXPLICIT base ref that does not resolve is CANNOT EVALUATE (exit 2).
run_checker "$G" "$REAL_REGISTRY" "$G/allow.tsv" "docs/contract.md" "no-such-ref-zzz" >/dev/null 2>"$WORK/5c.err"
rc=$?
[ "$rc" -eq 2 ] || fail "5c: an unresolvable explicit base ref should exit 2, got rc=$rc: $(cat "$WORK/5c.err")"
grep -q 'CANNOT EVALUATE' "$WORK/5c.err" || fail "5c: expected a CANNOT EVALUATE line, got: $(cat "$WORK/5c.err")"
ok "5c an unresolvable explicit base ref is CANNOT EVALUATE (exit 2)"

# --- 6. contract docs -------------------------------------------------------------
T="$WORK/t6"; make_tree "$T"
printf '# No pointer here\n\nJust prose.\n' >"$T/docs/nopointer.md"
out="$(run_checker "$T" "$REAL_REGISTRY" "$T/allow.tsv" "docs/nopointer.md" 2>&1)" && fail "6: a doc with no pointer should fail:
$out"
case "$out" in *"DOC-CITATION-MISSING  docs/nopointer.md"*) ;; *) fail "6: expected DOC-CITATION-MISSING, got:
$out" ;; esac
ok "6 a contract doc with no registry pointer is DOC-CITATION-MISSING (RED)"

{
  printf '# Points at ontology-registry.tsv but restates\n\n| Label | Meaning |\n|---|---|\n'
  printf '| `%s:backlog` | restated |\n' "$F_STATUS"
} >"$T/docs/restates.md"
out="$(run_checker "$T" "$REAL_REGISTRY" "$T/allow.tsv" "docs/restates.md" 2>&1)" && fail "6b: a doc tabling a registry token should fail:
$out"
case "$out" in *"DOC-RESTATES  docs/restates.md:5 restates registry token '$F_STATUS:backlog'"*) ;; *) fail "6b: expected DOC-RESTATES at line 5, got:
$out" ;; esac
ok "6b a contract doc tabling a registry token is DOC-RESTATES (RED)"

printf '# Points at ontology-registry.tsv\n\n- [m] <title> ...  # restated grammar\n' >"$T/docs/grammar.md"
out="$(run_checker "$T" "$REAL_REGISTRY" "$T/allow.tsv" "docs/grammar.md" 2>&1)" && fail "6c: a doc restating the sentinel grammar should fail:
$out"
case "$out" in *"DOC-RESTATES  docs/grammar.md:3 restates the sentinel grammar"*) ;; *) fail "6c: expected DOC-RESTATES (grammar) at line 3, got:
$out" ;; esac
ok "6c a contract doc restating the sentinel example grammar is DOC-RESTATES (RED)"

# --- 7. route drift, both directions ------------------------------------------
T="$WORK/t7"; make_tree "$T"
# 7a: the resolver emits a route the registry lacks.
cat >"$T/issue-state.sh" <<'EOF'
    "route": "fresh|adopt|question-first|claimed-elsewhere|already-done|
              ambiguous|not-an-issue|not-found|probe-failed|brand-new-route",
EOF
out="$(run_checker "$T" 2>&1)" && fail "7a: a resolver route absent from the registry should fail:
$out"
case "$out" in *"ROUTE-DRIFT  issue-state.sh emits route 'brand-new-route' but the registry"*) ;; *) fail "7a: expected ROUTE-DRIFT (resolver side), got:
$out" ;; esac
ok "7a a resolver route the registry does not list is ROUTE-DRIFT (RED)"
# 7b: the registry lists a route the resolver does not emit.
write_resolver "$T/issue-state.sh"
sed 's/^state:route\tfresh\t/state:route\tfresh-renamed\t/' "$REAL_REGISTRY" >"$T/registry.tsv"
grep -q '^state:route	fresh-renamed	' "$T/registry.tsv" || fail "7b: fixture registry edit did not take"
out="$(run_checker "$T" "$T/registry.tsv" 2>&1)" && fail "7b: a registry route the resolver does not emit should fail:
$out"
case "$out" in *"ROUTE-DRIFT  registry lists route 'fresh-renamed'"*"ROUTE-DRIFT  issue-state.sh emits route 'fresh'"*|*"ROUTE-DRIFT  issue-state.sh emits route 'fresh'"*"ROUTE-DRIFT  registry lists route 'fresh-renamed'"*) ;; *) fail "7b: expected ROUTE-DRIFT in both directions, got:
$out" ;; esac
ok "7b a registry route the resolver does not emit is ROUTE-DRIFT (RED)"

# --- 8. malformed registry ---------------------------------------------------------
T="$WORK/t8"; make_tree "$T"
{
  cat "$REAL_REGISTRY"
  printf 'node\tThreeFields\t-\n'
  printf 'no-such-axis\tToken\t-\tdetail\n'
  printf 'node\tEpic\t-\tduplicate of the real Epic row\n'
} >"$T/registry.tsv"
out="$(run_checker "$T" "$T/registry.tsv" 2>&1)" && fail "8: malformed rows should fail:
$out"
case "$out" in *"MALFORMED  registry row needs 4 tab-separated fields"*"ThreeFields"*) ;; *) fail "8: expected MALFORMED (3 fields), got:
$out" ;; esac
case "$out" in *"MALFORMED  unknown axis 'no-such-axis'"*) ;; *) fail "8: expected MALFORMED (unknown axis), got:
$out" ;; esac
case "$out" in *"DUPLICATE  (node, Epic)"*) ;; *) fail "8: expected DUPLICATE (node, Epic), got:
$out" ;; esac
ok "8 a 3-field row, an unknown axis and a duplicate (axis, token) are each named (RED)"
grep -v '^source	' "$REAL_REGISTRY" >"$T/registry.tsv"
out="$(run_checker "$T" "$T/registry.tsv" 2>&1)" && fail "8b: a required axis with no row should fail:
$out"
case "$out" in *"MISSING-AXIS  registry carries no row on required axis 'source'"*) ;; *) fail "8b: expected MISSING-AXIS for source, got:
$out" ;; esac
ok "8b a required axis with no row is MISSING-AXIS (RED)"

# --- 9. degenerate registry input never exits 0 -----------------------------------
T="$WORK/t9"; make_tree "$T"
run_checker "$T" "$T/absent-registry.tsv" >/dev/null 2>&1 && fail "9: an absent registry exited 0"
ok "check-ontology-registry.sh [absent]: exits non-zero, never a silent OK"
printf 'x\n' >"$T/unreadable.tsv"; chmod 000 "$T/unreadable.tsv"
run_checker "$T" "$T/unreadable.tsv" >/dev/null 2>&1 && fail "9: an unreadable registry exited 0"
chmod 644 "$T/unreadable.tsv"
ok "check-ontology-registry.sh [unreadable]: exits non-zero, never a silent OK"
: >"$T/empty.tsv"
out="$(run_checker "$T" "$T/empty.tsv" 2>&1)" && fail "9: an empty registry exited 0"
case "$out" in *"EMPTY-REGISTRY"*) ;; *) fail "9: expected EMPTY-REGISTRY, got:
$out" ;; esac
ok "check-ontology-registry.sh [empty]: exits non-zero, never a silent OK"

# --- 10. GREEN against the real tree (the live gate's own invocation) -------------
out="$(bash "$CHECKER" 2>&1)" || fail "10: the live gate is RED on this tree:
$out"
case "$out" in *"[ok]"*) ;; *) fail "10: expected the [ok] summary on the real tree, got:
$out" ;; esac
ok "10 the real tree is GREEN (live invocation)"

echo "ALL PASS: check-ontology-registry.sh ($REPO_ROOT)"
