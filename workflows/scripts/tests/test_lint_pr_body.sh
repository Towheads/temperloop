#!/usr/bin/env bash
#
# Unit tests for workflows/scripts/lint-pr-body.sh — the PR-body issue-linkage
# lint. Zero network, zero fixtures: each case feeds a body on stdin (plus
# optional --expect N) and asserts the lint's exit status and a substring of its
# message. Lives under tests/ so the strict whole-tree shellcheck step skips it;
# wired into `make lint-pr-body-test` (run by the `checks` CI job).
#
# Acceptance coverage (issue #196):
#   - bare `Closes #N` present (PASS)
#   - backticked `Closes #N` (FAIL — GitHub silently ignores it)
#   - negated `does not close #N` (FAIL — GitHub honors it despite negation)
#   - stray extra `Fixes #M` alongside the intended close (FAIL)
#
# Plus (temperloop#94, plan item `template-lints`): --require-verification, the
# opt-in static check for the PR-body skeleton template's required
# Verification-surface slot (a `## Verification` heading) — off by default so
# the acceptance-coverage cases above are unaffected.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$(cd "$HERE/.." && pwd)/lint-pr-body.sh"

pass=0
fail=0

# expect_exit <name> <wanted_exit> <body> [args...]
# Pipes <body> into the lint with the given args; asserts exit code.
expect_exit() {
	local name="$1" want="$2" body="$3"
	shift 3
	local out got
	out="$(printf '%b' "$body" | bash "$LINT" "$@" 2>&1)" && got=0 || got=$?
	if [ "$got" = "$want" ]; then
		printf '  ok   %s (exit %s)\n' "$name" "$got"
		pass=$((pass + 1))
	else
		printf '  FAIL %s — wanted exit %s, got %s\n' "$name" "$want" "$got"
		printf '       output: %s\n' "$out"
		fail=$((fail + 1))
	fi
}

# expect_msg <name> <body> <needle> [args...]
# Asserts the lint's output contains <needle> (a stable phrase) AND that it
# exited non-zero (a violation).
expect_msg() {
	local name="$1" body="$2" needle="$3"
	shift 3
	local out got
	out="$(printf '%b' "$body" | bash "$LINT" "$@" 2>&1)" && got=0 || got=$?
	if [ "$got" != 0 ] && printf '%s' "$out" | grep -qF -- "$needle"; then
		printf '  ok   %s (msg matched)\n' "$name"
		pass=$((pass + 1))
	else
		printf '  FAIL %s — wanted non-zero exit + message containing: %s\n' "$name" "$needle"
		printf '       exit=%s output: %s\n' "$got" "$out"
		fail=$((fail + 1))
	fi
}

echo "== lint-pr-body.sh tests =="

# --- Acceptance criterion 1: intended Closes present and BARE ---------------
expect_exit "bare Closes present + --expect (PASS)" 0 \
	'This PR adds a lint.\n\nCloses #196\n' --expect 196

expect_exit "bare Closes uppercase + --expect (PASS)" 0 \
	'CLOSES #196\n' --expect 196

expect_exit "bare Closes with colon + --expect (PASS)" 0 \
	'Closes: #196\n' --expect 196

expect_msg "backticked Closes + --expect (FAIL: silently ignored)" \
	'Adds a lint.\n\n`Closes #196`\n' 'SILENTLY IGNORE' --expect 196

expect_msg "fenced-block Closes + --expect (FAIL: absent on honored surface)" \
	'Example body:\n```\nCloses #196\n```\n' "intended 'Closes #196'" --expect 196

expect_msg "absent Closes + --expect (FAIL)" \
	'A refactor with no linkage line.\n' 'ABSENT' --expect 196

# --- Acceptance criterion 2: stray/other honored close flagged --------------
expect_msg "stray extra Fixes #M alongside intended (FAIL)" \
	'Closes #196\n\nAlso Fixes #999 while we are here.\n' 'WILL honor' --expect 196

expect_exit "stray extra close exits non-zero" 1 \
	'Closes #196\n\nResolves #777 too.\n' --expect 196

# --- Acceptance criterion 3: negated close flagged --------------------------
expect_msg "negated 'does not close #N' (FAIL: negation ignored by GitHub)" \
	'Note: it does not close #367, that is a separate issue.\n' 'NEGATED'

expect_msg "contraction won't fix #N (FAIL)" \
	"This PR won't fix #42 in this round.\n" 'NEGATED'

expect_msg "contraction doesn't close #N (FAIL)" \
	"It doesn't close #50.\n" 'NEGATED'

expect_exit "negated close exits non-zero (no --expect)" 1 \
	'We will not resolve #88 here.\n'

# --- Clean / no-op cases (PASS) ---------------------------------------------
expect_exit "plain bare close, no --expect (PASS: legit close)" 0 \
	'Closes #196\n'

expect_exit "bare issue reference, no keyword (PASS)" 0 \
	'See issue #196 for background; relates to #200.\n'

expect_exit "empty-ish body, no linkage (PASS)" 0 \
	'Just a chore, nothing to link.\n'

expect_exit "backticked close, no --expect (PASS: GitHub ignores it)" 0 \
	'Documenting the trap: a `Closes #5` is silently ignored.\n'

# --- --require-verification: opt-in parsed-surface check ---------------------
expect_exit "no --require-verification flag, no Verification section (PASS: opt-in, off by default)" 0 \
	'Adds a lint.\n\nCloses #196\n'

expect_msg "--require-verification with no Verification section (FAIL)" \
	'Adds a lint.\n\nCloses #196\n' "no '## Verification' section" --require-verification --expect 196

expect_exit "--require-verification with a Verification section present (PASS)" 0 \
	'Adds a lint.\n\n## Verification\n\nRun the tests.\n\nCloses #196\n' --require-verification --expect 196

expect_exit "--require-verification with a 'Verification surface' heading (PASS: prefix match)" 0 \
	'Adds a lint.\n\n## Verification surface\n\nRun the tests.\n' --require-verification

# ---------------------------------------------------------------------------
echo
printf 'lint-pr-body.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
