#!/usr/bin/env bash
#
# Tests for check-reviewer-routing.sh (ADR 0008,
# docs/adr/0008-reviewer-routing-tsv-extension-axis-scope.md): a synthetic
# fixture tree proves the structural duplicate-key check, the citation
# check, the set-membership drift check (a tsv key's literal backtick-quoted
# form reappearing in build.md's 3e prose), and the GREEN path a clean tsv +
# prose pair produces.
#
# Mirrors the sibling test_check_knob_prose.sh's plain mktemp-fixture style
# (REVIEWER_ROUTING_TSV / REVIEWER_ROUTING_BUILD_MD env overrides point the
# checker at a throwaway fixture pair, no git repo needed).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-reviewer-routing.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reviewer-routing-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

run_checker() {
  (
    REVIEWER_ROUTING_TSV="$WORK/routing.tsv"
    REVIEWER_ROUTING_BUILD_MD="$WORK/build.md"
    export REVIEWER_ROUTING_TSV REVIEWER_ROUTING_BUILD_MD
    bash "$CHECKER"
  )
}

clean_tsv() {
  cat >"$WORK/routing.tsv" <<'EOF'
# extension-or-path-glob	reviewer-name	catalog-agent-path
.py	python-reviewer	claude/agents/reviewers/python-reviewer.md
.sh	shell-reviewer	claude/agents/reviewers/shell-reviewer.md
docs/**	docs-reviewer	claude/agents/docs-reviewer.md
EOF
}

clean_build_md() {
  cat >"$WORK/build.md" <<'EOF'
#### 3e. Optional pre-push review

If project CLAUDE.md `## Subagents` lists a review subagent matching the
item's `review:` override, the item's change *kind* (`architectural` ->
`architecture-reviewer`), or the extension/path-glob axis --
`workflows/scripts/config/reviewer-routing.tsv` is the single source of
truth for that axis -- except a workflow spec under `claude/commands/*.md`,
which always routes to `workflow-reviewer`, invoke as read-only pass.

#### 3e.5. Parent-side acceptance gate

Unrelated section, not scanned.
EOF
}

# --- 1. GREEN: clean tsv + clean prose --------------------------------------
clean_tsv
clean_build_md
out="$(run_checker 2>&1)" || fail "1: clean tsv + prose should pass:
$out"
case "$out" in
  *"OK — reviewer-routing.tsv (3 extension/glob row(s))"*) ;;
  *) fail "1: expected the OK summary line, got:
$out" ;;
esac
echo "PASS: 1 clean tsv + clean prose passes (GREEN)"

# --- 2. RED: duplicate key claimed by two rows ------------------------------
clean_tsv
printf '.py\tanother-py-reviewer\tclaude/agents/reviewers/another.md\n' >>"$WORK/routing.tsv"
clean_build_md
out="$(run_checker 2>&1)" && fail "2: duplicate key should fail:
$out"
case "$out" in
  *"DUPLICATE: .py is claimed by two rows"*) ;;
  *) fail "2: expected a DUPLICATE violation for .py, got:
$out" ;;
esac
echo "PASS: 2 duplicate key correctly flagged (RED)"

# --- 3. RED: build.md's 3e section doesn't cite the tsv ---------------------
clean_tsv
cat >"$WORK/build.md" <<'EOF'
#### 3e. Optional pre-push review

Route by change kind (`architectural` -> `architecture-reviewer`) or by a
per-item `review:` override, invoke as read-only pass.

#### 3e.5. Parent-side acceptance gate

Unrelated section, not scanned.
EOF
out="$(run_checker 2>&1)" && fail "3: missing citation should fail:
$out"
case "$out" in
  *"CITATION MISSING"*) ;;
  *) fail "3: expected a CITATION MISSING violation, got:
$out" ;;
esac
echo "PASS: 3 missing tsv citation correctly flagged (RED)"

# --- 4. RED: a tsv key's route reappears literally in build.md's 3e prose --
clean_tsv
cat >"$WORK/build.md" <<'EOF'
#### 3e. Optional pre-push review

If project CLAUDE.md `## Subagents` lists a review subagent matching the
item's `review:` override (or change kind -- `.py` -> `python-reviewer`,
architectural -> `architecture-reviewer`), consult
`workflows/scripts/config/reviewer-routing.tsv` for the rest, invoke as
read-only pass.

#### 3e.5. Parent-side acceptance gate

Unrelated section, not scanned.
EOF
out="$(run_checker 2>&1)" && fail "4: reintroduced inline route should fail:
$out"
case "$out" in
  *"DRIFT: tsv key .py (-> python-reviewer) reappears literally"*) ;;
  *) fail "4: expected a DRIFT violation for .py, got:
$out" ;;
esac
echo "PASS: 4 tsv route reappearing literally in prose correctly flagged (RED)"

# --- 5. GREEN: the sanctioned claude/commands/*.md exception glob is fine --
# (it is not a tsv key, so mentioning it must never trip the lint)
clean_tsv
clean_build_md
out="$(run_checker 2>&1)" || fail "5: the claude/commands/*.md exception glob should not trip the lint:
$out"
echo "PASS: 5 the non-tsv claude/commands/*.md exception glob is not a violation (GREEN)"

# --- 6. RED: no '#### 3e.' section found in build.md at all ----------------
clean_tsv
cat >"$WORK/build.md" <<'EOF'
#### 3d. Something else entirely

No 3e section here.
EOF
out="$(run_checker 2>&1)" && fail "6: missing 3e section should fail:
$out"
case "$out" in
  *"no '#### 3e.' section found"*) ;;
  *) fail "6: expected a missing-section error, got:
$out" ;;
esac
echo "PASS: 6 a build.md with no 3e section fails legibly"

echo "ALL PASS: check-reviewer-routing.sh"
