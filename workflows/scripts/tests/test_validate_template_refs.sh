#!/usr/bin/env bash
#
# test_validate_template_refs.sh — fixture + real-tree tests for
# workflows/scripts/validate-template-refs.sh, focused on the NON-OVERRIDABLE
# TEMPLATE SET (temperloop#928, plan item `decision-presentation-template`).
#
# Why this suite exists at all: claude/message-schema.md § Overrides excludes
# § Decision presentation from the sanctioned overlay-override surface, and
# claude/CLAUDE.kernel.md § Kernel vs overlay routing rule's carve-out points
# at that exclusion. Prose alone cannot enforce it — an excluded template's
# name IS canonical, so before the exclusion check existed an overlay
# shipping `### Decision presentation` passed the dangling-override check
# cleanly, exactly like a sanctioned override. This suite proves the
# enforcement in BOTH directions: RED on an overlay that redeclares an
# excluded name, GREEN on the tree and on an overlay that redeclares a
# sanctioned one. Asserting only the green side would ship the enforcement
# unproven — a check that never fails is indistinguishable from no check.
#
# Covered:
#   1. real-tree green (no overlay present -> trivial pass, exit 0)
#   2. RED — overlay redeclaring `### Decision presentation` -> exit 1, with
#      a message naming the template and the excluding section
#   3. GREEN — overlay redeclaring a SANCTIONED template (`### Parking note`)
#      -> exit 0; the exclusion is narrow, not a blanket ban on overrides
#   4. mixed overlay (one sanctioned + one excluded) -> exit 1, and the
#      sanctioned one still reports ok (the failure is per-name, not per-file)
#   5. RED — overlay redeclaring a name no template defines -> exit 1 (the
#      pre-existing dangling-override behavior, unbroken by the new check)
#   6. doc<->script consistency — every name in NON_OVERRIDABLE_TEMPLATES is
#      still a `### <Name>` heading under message-schema.md's `## Templates`
#   7. wiring — message-schema.md § Overrides and CLAUDE.kernel.md's carve-out
#      both name the exclusion, so neither side of the two-site contract is a
#      dangling pointer
#
# Hermetic: overlay fixtures are throwaway files under a tmpdir, injected via
# the script's own MESSAGE_SCHEMA_OVERLAY seam. Never writes into the
# checkout, never touches the network, and never creates a real
# claude/message-schema.overlay.md (which would change the tree's own gate
# result for every other suite).
#
# Usage: bash workflows/scripts/tests/test_validate_template_refs.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-template-refs.sh"
MSG_SCHEMA="$REPO/claude/message-schema.md"
KERNEL_MD="$REPO/claude/CLAUDE.kernel.md"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-validate-template-refs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# run_with_overlay <overlay-path-or-empty> — runs the lint with the overlay
# seam pointed at <path> (or at a deliberately absent path when empty),
# leaving the combined output in OUT and the exit code in RC. Deliberately
# NOT a command substitution at the call site: `out="$(f)"` runs f in a
# subshell, so an rc the function assigns there never reaches the caller —
# every rc assertion would silently read a stale 0.
OUT=""
RC=0
run_with_overlay() {
  local overlay="${1:-$TMP/absent-on-purpose.md}"
  MESSAGE_SCHEMA_OVERLAY="$overlay" bash "$SCRIPT" >"$TMP/out.txt" 2>&1
  RC=$?
  OUT="$(cat "$TMP/out.txt")"
}

# ── 1. real tree, no overlay: green ────────────────────────────────────────
echo "--- 1. real tree, no overlay present ---"
run_with_overlay ""
out="$OUT"
assert_rc "$RC" 0 "unmodified real tree exits 0"
assert_has "$out" "validate-template-refs: OK" "reports OK"
assert_has "$out" "non-overridable templates" "prints the non-overridable set for the reader"
assert_has "$out" "0 overrides to check" "absent overlay is a trivial pass, not an error"

# ── 2. RED: overlay redeclares a NON-OVERRIDABLE template ──────────────────
echo "--- 2. overlay redeclares '### Decision presentation' (must FAIL) ---"
cat >"$TMP/overlay-excluded.md" <<'MD'
# Message schema overlay

## Templates

### Decision presentation

A shorter, laxer local copy that drops the plain-language rule.
MD
run_with_overlay "$TMP/overlay-excluded.md"
out="$OUT"
assert_rc "$RC" 1 "redeclaring an excluded template exits 1"
assert_has "$out" "NON-OVERRIDABLE" "failure names the exclusion, not a generic dangling-override"
assert_has "$out" "Decision presentation" "failure names the offending template"
assert_has "$out" "§ Overrides" "failure points at the section that owns the exclusion"
assert_has "$out" "validate-template-refs: FAIL" "final verdict is FAIL"

# ── 3. GREEN: overlay redeclares a SANCTIONED template ─────────────────────
echo "--- 3. overlay redeclares '### Parking note' (must PASS) ---"
cat >"$TMP/overlay-sanctioned.md" <<'MD'
# Message schema overlay

## Templates

### Parking note

A local redeclaration of a template the kernel DOES let an overlay override.
MD
run_with_overlay "$TMP/overlay-sanctioned.md"
out="$OUT"
assert_rc "$RC" 0 "redeclaring a sanctioned template still exits 0"
assert_has "$out" 'ok    overlay override "Parking note"' "sanctioned override reports ok"

# ── 4. mixed overlay: per-name verdicts, not per-file ──────────────────────
echo "--- 4. overlay with one sanctioned + one excluded name ---"
cat >"$TMP/overlay-mixed.md" <<'MD'
# Message schema overlay

## Templates

### Parking note

Fine.

### Decision presentation

Not fine.
MD
run_with_overlay "$TMP/overlay-mixed.md"
out="$OUT"
assert_rc "$RC" 1 "one excluded name reds the whole run"
assert_has "$out" 'ok    overlay override "Parking note"' "the sanctioned name is still reported ok"
assert_has "$out" 'FAIL  overlay override "Decision presentation"' "the excluded name is reported FAIL"

# ── 5. RED: pre-existing dangling-override behavior is unbroken ────────────
echo "--- 5. overlay redeclares a name no template defines ---"
cat >"$TMP/overlay-dangling.md" <<'MD'
# Message schema overlay

## Templates

### Nonexistent placeholder shape

Overrides nothing.
MD
run_with_overlay "$TMP/overlay-dangling.md"
out="$OUT"
assert_rc "$RC" 1 "a dangling override name still exits 1"
assert_has "$out" "does not match any kernel-defined template" "dangling override keeps its own distinct message"

# ── 6. doc<->script consistency: every excluded name is still canonical ────
echo "--- 6. NON_OVERRIDABLE_TEMPLATES entries resolve in message-schema.md ---"
excluded="$(sed -n "s/^NON_OVERRIDABLE_TEMPLATES='\(.*\)'$/\1/p" "$SCRIPT")"
if [ -z "$excluded" ]; then
  fail_test "exclusion set is parseable from the script" "NON_OVERRIDABLE_TEMPLATES not found in $SCRIPT"
else
  ok "exclusion set is parseable from the script"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if awk -v want="### $name" '
      /^## Templates/ { insec = 1; next }
      insec && /^## /  { insec = 0 }
      insec && $0 == want { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$MSG_SCHEMA"; then
      ok "excluded template \"$name\" is defined under § Templates"
    else
      fail_test "excluded template \"$name\" is defined under § Templates" \
        "no '### $name' heading under '## Templates' in $MSG_SCHEMA"
    fi
  done <<EOF
$excluded
EOF
fi

# ── 7. wiring: both prose sites name the exclusion ─────────────────────────
echo "--- 7. two-site contract has no dangling half ---"
if grep -q 'Non-overridable set' "$MSG_SCHEMA"; then
  ok "message-schema.md § Overrides declares the non-overridable set"
else
  fail_test "message-schema.md § Overrides declares the non-overridable set" "bullet not found"
fi
if grep -q 'NON_OVERRIDABLE_TEMPLATES' "$MSG_SCHEMA"; then
  ok "message-schema.md names the script-side variable (edit contract is discoverable)"
else
  fail_test "message-schema.md names the script-side variable" "NON_OVERRIDABLE_TEMPLATES not referenced"
fi
if grep -q 'non-overridable set' "$KERNEL_MD"; then
  ok "CLAUDE.kernel.md's overlay carve-out is qualified by the exclusion"
else
  fail_test "CLAUDE.kernel.md's overlay carve-out is qualified by the exclusion" \
    "the carve-out still reads as though every named template is redeclarable"
fi
if grep -q 'validate-template-refs.sh' "$KERNEL_MD"; then
  ok "CLAUDE.kernel.md names the enforcing lint"
else
  fail_test "CLAUDE.kernel.md names the enforcing lint" "validate-template-refs.sh not referenced"
fi

echo
echo "test_validate_template_refs: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
