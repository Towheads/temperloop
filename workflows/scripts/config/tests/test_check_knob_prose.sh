#!/usr/bin/env bash
#
# Tests for check-knob-prose.sh (temperloop#164/#169, item
# registry-config-lints): a synthetic fixture tree proves the RED path (a
# knob name + its registered default restated in the same prose line), the
# GREEN paths (name-only prose; the value shown only inside a backtick code
# span; the value inside a fenced code block; a name that is a substring of
# a longer identifier), the `<!-- knob-prose:allow -->` marker, the numeric
# unit-suffix catch ("300s" still counts as restating 300), and the
# burn-down baseline's consumed-once semantics (a baselined line passes; a
# NEW duplicate of that same line still fails).
#
# Mirrors the sibling test_check_knob_registry.sh's plain mktemp-fixture
# style (no git repo needed here — check-knob-prose.sh scans a fixed
# claude/commands/*.md + claude/CLAUDE.kernel.md set by path, not via
# git ls-files).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-knob-prose.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/knob-prose-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT/claude/commands"

cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_WINDOW	300	seconds	kernel	scripts/a.sh	timed window
KNOB_MODE	auto	enum	kernel	scripts/a.sh	mode selector (auto|on|off)
KNOB_INTERP	$SOME_DIR/file	path	kernel	scripts/a.sh	interpolated default — never a prose candidate
EOF

run_checker() {
  (
    KNOB_REGISTRY_FILE="$WORK/kernel.tsv"
    KNOB_REGISTRY_OVERLAY_FILE="$WORK/absent-overlay.tsv"
    KNOB_PROSE_SCAN_ROOT="$ROOT"
    KNOB_PROSE_BASELINE_FILE="$WORK/baseline.tsv"
    export KNOB_REGISTRY_FILE KNOB_REGISTRY_OVERLAY_FILE
    export KNOB_PROSE_SCAN_ROOT KNOB_PROSE_BASELINE_FILE
    bash "$CHECKER"
  )
}

: >"$WORK/baseline.tsv"

# --- 1. GREEN: name-only prose (the D3-compliant shape) --------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window is `KNOB_WINDOW` (see the knob registry for its default).
EOF
cat >"$ROOT/claude/CLAUDE.kernel.md" <<'EOF'
Nothing knob-related here.
EOF
out="$(run_checker 2>&1)" || fail "1: name-only prose should pass:
$out"
echo "PASS: 1 name-only prose passes (GREEN)"

# --- 2. RED: name + default restated in the same prose line ----------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window is `KNOB_WINDOW`, default 300 seconds.
EOF
out="$(run_checker 2>&1)" && fail "2: restated default should fail:
$out"
case "$out" in
  *"PROSE: claude/commands/spec.md:1: KNOB_WINDOW"*) ;;
  *) fail "2: expected a PROSE violation for KNOB_WINDOW, got:
$out" ;;
esac
echo "PASS: 2 name + restated default correctly flagged (RED)"

# --- 3. RED: numeric unit suffix still counts ("300s") ----------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window (`KNOB_WINDOW`, default 300s) auto-merges.
EOF
out="$(run_checker 2>&1)" && fail "3: '300s' unit-suffixed restatement should fail:
$out"
echo "PASS: 3 unit-suffixed numeric restatement (300s) correctly flagged (RED)"

# --- 4. GREEN: value only inside a backtick code span ----------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
Override the window via `KNOB_WINDOW=300` on the command line.
EOF
out="$(run_checker 2>&1)" || fail "4: value inside a code span should pass:
$out"
echo "PASS: 4 value inside a backtick code span is not a violation (GREEN)"

# --- 5. GREEN: value inside a fenced code block ------------------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
Set the knob KNOB_WINDOW before running:

```sh
KNOB_WINDOW=300 run-the-thing   # 300 is fine here
```
EOF
out="$(run_checker 2>&1)" || fail "5: value inside a fenced block should pass:
$out"
echo "PASS: 5 value inside a fenced code block is not a violation (GREEN)"

# --- 6. GREEN: allow-marker suppresses a legitimate literal ------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window is `KNOB_WINDOW`, default 300 seconds. <!-- knob-prose:allow — this doc line is the worked example the marker exists for -->
EOF
out="$(run_checker 2>&1)" || fail "6: allow-marker line should pass:
$out"
echo "PASS: 6 <!-- knob-prose:allow --> marker suppresses the line (GREEN)"

# --- 7. GREEN: name-substring of a longer identifier doesn't count ---------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
`KNOB_MODE_EXTENDED` is a different knob entirely; auto is mentioned freely here.
EOF
out="$(run_checker 2>&1)" || fail "7: longer-identifier substring should pass:
$out"
echo "PASS: 7 knob name as substring of a longer identifier is not a name hit (GREEN)"

# --- 8. RED then GREEN: enum default ("auto") next to its name --------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
`KNOB_MODE` selects the backend, default auto.
EOF
out="$(run_checker 2>&1)" && fail "8a: enum default restatement should fail:
$out"
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
`KNOB_MODE` selects the backend; see the registry for its default.
EOF
out="$(run_checker 2>&1)" || fail "8b: name-only rewrite should pass:
$out"
echo "PASS: 8 enum default restatement RED, name-only rewrite GREEN"

# --- 9. baseline suppression is consumed-once --------------------------------
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window is `KNOB_WINDOW`, default 300 seconds.
EOF
printf '%s\t%s\t%s\t%s\n' \
  "claude/commands/spec.md" "KNOB_WINDOW" "300" \
  "The timed window is \`KNOB_WINDOW\`, default 300 seconds." \
  >"$WORK/baseline.tsv"
out="$(run_checker 2>&1)" || fail "9a: baselined violation should pass:
$out"
case "$out" in
  *"1 pre-existing hit(s) suppressed"*) ;;
  *) fail "9a: expected the baselined-count report, got:
$out" ;;
esac
# a NEW duplicate of the same line (2 occurrences, 1 baseline row) still fails
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
The timed window is `KNOB_WINDOW`, default 300 seconds.
The timed window is `KNOB_WINDOW`, default 300 seconds.
EOF
out="$(run_checker 2>&1)" && fail "9b: a new duplicate beyond the baseline row should fail:
$out"
echo "PASS: 9 baseline suppresses exactly one occurrence; a new duplicate still fails"

# --- 10. CLAUDE.kernel.md is scanned too -------------------------------------
: >"$WORK/baseline.tsv"
cat >"$ROOT/claude/commands/spec.md" <<'EOF'
Nothing here.
EOF
cat >"$ROOT/claude/CLAUDE.kernel.md" <<'EOF'
The `KNOB_MODE` knob defaults to auto per the config.
EOF
out="$(run_checker 2>&1)" && fail "10: CLAUDE.kernel.md violation should fail:
$out"
case "$out" in
  *"PROSE: claude/CLAUDE.kernel.md:1: KNOB_MODE"*) ;;
  *) fail "10: expected a violation attributed to claude/CLAUDE.kernel.md, got:
$out" ;;
esac
echo "PASS: 10 claude/CLAUDE.kernel.md is scanned (RED there too)"

echo "ALL PASS: check-knob-prose.sh"
