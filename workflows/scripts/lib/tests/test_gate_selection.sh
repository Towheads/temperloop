#!/usr/bin/env bash
#
# Tests for gate-selection.sh — the diff-scoped gate selector
# scripts/quality-gates.sh uses on `pull_request` runs (temperloop#1024).
#
# The whole value of this suite is that it proves the DEGRADATIONS, which are
# the only thing standing between diff-scoping and the silent-green failure
# class. Every case below asserts one of two things: either the selector
# narrowed correctly, or it refused to narrow and said why.
#
# Coverage:
#   1. Not a pull_request event -> FULL set (the merge_group / push:main /
#      local / worker path, i.e. everything that gates `main`).
#   2. QUALITY_GATES_SCOPE=full -> FULL set even on a pull_request.
#   3. An unrecognised QUALITY_GATES_SCOPE -> FULL set (fail toward coverage).
#   4. Happy path: changed paths select exactly their mapped gates, plus every
#      ALWAYS gate, in the caller's run order.
#   5. UNMAPPED PATH -> FULL set. The headline safety property.
#   6. ALL escalation glob -> FULL set.
#   7. `none` row: a recognised path that maps to no gate does NOT escalate,
#      and does NOT drag in unrelated gates.
#   8. An ALWAYS row is not a path recogniser — otherwise its implicit
#      whole-tree scope would match every path and case 5 could never fire.
#   9. UNMAPPED GATE still runs (over-run, never under-run).
#  10. Malformed map -> FULL set, with a stderr complaint.
#  11. Missing map file -> FULL set.
#  12. Unresolvable base -> FULL set (real git, real repo).
#  13. Empty diff -> FULL set.
#  14. End-to-end against a REAL git repo: a two-commit repo, a real
#      `git diff base...HEAD`, and a real narrowing decision.
#  15. Globs are never pathname-expanded against the working directory.
#
# temperloop#957 added a SECOND consumer — `quality-gates.sh --scoped`, the
# /build item worker's mid-work run — and with it two more things that must be
# proven, since a worker's run is read by a model rather than a CI dashboard:
#  16. `GATE_SELECTION_SKIPPED` is the EXACT complement of `_SELECTED` (the
#      scoped run can name everything it did not run).
#  17. A full run reports an EMPTY skip list.
#  18. `gate_selection_local_changed` unions committed + staged + unstaged +
#      untracked paths, and excludes ignored ones.
#  19. No resolvable default-branch base -> non-zero, so the caller runs the
#      FULL set rather than narrowing on the working-tree half alone.
#  20. A non-git directory -> non-zero (never an empty, silently-narrowing set).
#
# temperloop#1931 added GENERIC new-surface globs to gate-paths.tsv so a
# brand-new check-*/validate-*/test_* script selects the check-surface and
# exec-bit registry validators before it is even registered:
#  21. A depth-0 and a nested brand-new candidate-shaped path each select all
#      four registry-validator gates against the REAL gate-paths.tsv.
#
# temperloop#1933 carved the ONE content-checked exception to the ALL row: a
# registration-only scripts/quality-gates.sh diff selects the registry
# validators rather than the whole suite. Both shapes are proven:
#  22. a) registration-only  -> diff mode, registry validators + the newly
#         registered gate, an unrelated mapped gate still skipped;
#      b) a removed line, c) a non-registration addition, d) comments only,
#      e) a splat registration, f) no readable diff -> FULL escalation, each.
#      g/h) the same two verdicts end-to-end against a REAL git tree, with the
#         uncommitted half of the diff carrying its own veto.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# shellcheck source=../gate-selection.sh
source "$LIB_DIR/gate-selection.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAP="$TMP/gate-paths.tsv"
cat >"$MAP" <<'EOF'
# fixture map
ALL	Makefile scripts/quality-gates.sh
none	LICENSE
make test-always	ALWAYS
make test-docs	docs/**
make test-lib	src/lib/** src/shared.sh
make test-cli	src/cli/**
EOF

ALL_GATES='make test-always
make test-docs
make test-lib
make test-cli
make test-unmapped'

reset_env() {
  unset QUALITY_GATES_SCOPE GITHUB_EVENT_NAME GATE_SELECTION_CHANGED GATE_SELECTION_DIFF_TEXT
  GATE_SELECTION_ROOT="$TMP"
  GATE_SELECTION_MAP_FILE="$MAP"
  GATE_SELECTION_ALL_GATES="$ALL_GATES"
  GATE_SELECTION_BASE=""
}

# --- 1. not a pull_request event ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=merge_group
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "1: merge_group must run the FULL set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"is not pull_request"*) : ;; *) fail "1: reason should name the event (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 1 a non-pull_request event runs the full set"

# --- 2. QUALITY_GATES_SCOPE=full ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=pull_request
QUALITY_GATES_SCOPE=full
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "2: SCOPE=full must disable scoping"
echo "PASS: 2 QUALITY_GATES_SCOPE=full disables scoping"

# --- 3. unrecognised scope ---------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=sideways
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "3: an unrecognised scope must fail toward the full set"
case "$GATE_SELECTION_REASON" in *unrecognised*) : ;; *) fail "3: reason should say unrecognised (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 3 an unrecognised QUALITY_GATES_SCOPE falls back to the full set"

# --- 4. happy path -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
src/lib/thing.sh'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "4: expected a diff-scoped run (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-lib
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "4: wrong selection:
got:
$GATE_SELECTION_SELECTED
want:
$expected"
echo "PASS: 4 mapped paths select their gates (plus ALWAYS + unmapped), in run order"

# --- 5. an unmapped path escalates to the full set ---------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
somewhere/nobody/mapped.txt'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "5: an unmapped path MUST escalate to the full set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"somewhere/nobody/mapped.txt"*) : ;; *) fail "5: reason must NAME the unmapped path (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 5 an unmapped changed path escalates to the full set, naming the path"

# --- 6. ALL escalation -------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
Makefile'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "6: an ALL glob must escalate to the full set"
case "$GATE_SELECTION_REASON" in *"ALL escalation"*) : ;; *) fail "6: reason should name the ALL escalation (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 6 a path matching an ALL glob escalates to the full set"

# --- 7. `none` row -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='LICENSE'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "7: a `none`-mapped path must not escalate (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "7: a none-mapped path should select nothing beyond ALWAYS/unmapped, got:
$GATE_SELECTION_SELECTED"
echo "PASS: 7 a 'none'-mapped path is recognised but selects no gate"

# --- 8. an ALWAYS row is not a recogniser ------------------------------------
# `make test-always` carries no globs. If ALWAYS rows counted as recognisers
# (e.g. by being treated as `**`), the unmapped-path escalation in case 5 could
# never fire. Prove the recogniser set really excludes them.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='totally/unmapped'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "8: an ALWAYS row must not recognise arbitrary paths"
echo "PASS: 8 an ALWAYS row contributes nothing to path recognition"

# --- 9. an unmapped GATE always runs ----------------------------------------
# (asserted by cases 4 and 7 above, which both keep `make test-unmapped`.)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='src/cli/main.sh'
gate_selection_resolve
case "$GATE_SELECTION_SELECTED" in *"make test-unmapped"*) : ;; *) fail "9: a gate with no map row must still run" ;; esac
case "$GATE_SELECTION_SELECTED" in *"make test-docs"*) fail "9: test-docs should not have been selected by a src/cli path" ;; esac
echo "PASS: 9 a gate with no row in the map still runs (over-run, never under-run)"

# --- 10. malformed map -------------------------------------------------------
BADMAP="$TMP/bad.tsv"
printf 'no-tab-here\n' >"$BADMAP"
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$BADMAP"
GATE_SELECTION_CHANGED='docs/a.md'
# NB: stderr is redirected to a FILE, not captured by `$(...)` — a command
# substitution runs in a subshell, and the whole point of this call is the
# globals it sets in THIS shell.
gate_selection_resolve 2>"$TMP/err10"
err="$(cat "$TMP/err10")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "10: a malformed map must fall back to the full set"
case "$err" in *malformed*) : ;; *) fail "10: the malformed row should be announced on stderr (got: $err)" ;; esac
echo "PASS: 10 a malformed map falls back to the full set and says so"

# --- 11. missing map ---------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$TMP/does-not-exist.tsv"
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve 2>"$TMP/err11"
err="$(cat "$TMP/err11")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "11: a missing map must fall back to the full set"
case "$err" in *"not found"*) : ;; *) fail "11: the missing map should be announced (got: $err)" ;; esac
echo "PASS: 11 a missing map falls back to the full set and says so"

# --- 12/13/14. real git repo -------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/docs" "$REPO/src/lib"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo base >"$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

# 12. unresolvable base
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "12: an unresolvable base must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"no resolvable diff base"*) : ;; *) fail "12: reason should name the base problem (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 12 an unresolvable diff base falls back to the full set"

# 13. empty diff (base == HEAD)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "13: an empty diff must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"zero changed paths"*) : ;; *) fail "13: reason should name the empty diff (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 13 a diff with zero changed paths falls back to the full set"

# 14. a real narrowing decision over a real diff
echo hi >"$REPO/docs/guide.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm docs
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "14: a real docs-only diff should narrow (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "14: wrong real-git selection:
$GATE_SELECTION_SELECTED"
echo "PASS: 14 a real git diff narrows the run to the docs-affected gates"

# --- 15. globs are never pathname-expanded -----------------------------------
# A bare `for glob in $globs` would expand `docs/**` against the CWD, silently
# replacing the author's pattern with whatever happens to exist on disk. Run
# from a directory that HAS a `docs/` and prove the pattern still behaves as a
# pattern (matching a path that does NOT exist on disk).
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/never/created/on/disk.md'
( cd "$REPO" && gate_selection_resolve && [ "$GATE_SELECTION_MODE" = "diff" ] ) \
  || fail "15: a glob must be matched as a pattern, not pathname-expanded against the CWD"
echo "PASS: 15 globs are matched as patterns, never expanded against the working directory"

# --- 16. _SKIPPED is the exact complement of _SELECTED -----------------------
# The scoped run's whole safety story is that it can NAME what it did not run
# (temperloop#957). If _SKIPPED were computed loosely — or drifted from
# _SELECTED — a gate could be silently absent from both lists and a reader
# would have no way to notice. Assert the partition exactly.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "16: expected a diff-scoped run"
expected_skipped='make test-lib
make test-cli'
[ "$GATE_SELECTION_SKIPPED" = "$expected_skipped" ] || fail "16: wrong skipped set:
got:
$GATE_SELECTION_SKIPPED
want:
$expected_skipped"
union="$(printf '%s\n%s\n' "$GATE_SELECTION_SELECTED" "$GATE_SELECTION_SKIPPED" | sort)"
all_sorted="$(printf '%s\n' "$ALL_GATES" | sort)"
[ "$union" = "$all_sorted" ] || fail "16: selected+skipped must partition the full gate list exactly"
echo "PASS: 16 _SKIPPED names every un-run gate and partitions the list with _SELECTED"

# --- 17. a FULL run reports nothing skipped ----------------------------------
# A full run has nothing to disclose, and a stale _SKIPPED left over from a
# previous call would make one look scoped.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='Makefile'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "17: expected the ALL escalation"
[ -z "$GATE_SELECTION_SKIPPED" ] || fail "17: a full run must report an EMPTY skip list (got: $GATE_SELECTION_SKIPPED)"
echo "PASS: 17 a full run reports an empty skip list"

# --- 18. gate_selection_local_changed: commits + staged + unstaged + new -----
# The mid-work case (temperloop#957): a worker's changes are a MIX, and any
# source it misses is a gate it silently under-runs. Real git, real worktree.
LOCAL="$TMP/local"
mkdir -p "$LOCAL"
git -C "$LOCAL" init -q
git -C "$LOCAL" config user.email t@example.com
git -C "$LOCAL" config user.name t
mkdir -p "$LOCAL/src"
echo base >"$LOCAL/README.md"
git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm base
git -C "$LOCAL" branch -M main
git -C "$LOCAL" checkout -qb feature
echo committed >"$LOCAL/src/committed.sh"
git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm work
echo staged >"$LOCAL/src/staged.sh"
git -C "$LOCAL" add "$LOCAL/src/staged.sh"
echo unstaged >>"$LOCAL/README.md"
echo brand-new >"$LOCAL/src/untracked.sh"
printf 'ignored\n' >"$LOCAL/.gitignore"
git -C "$LOCAL" add "$LOCAL/.gitignore" && git -C "$LOCAL" commit -qm ignore
echo junk >"$LOCAL/ignored"
got="$(gate_selection_local_changed "$LOCAL")" || fail "18: local changed-set resolution failed"
for want in src/committed.sh src/staged.sh README.md src/untracked.sh; do
  case "$got" in *"$want"*) : ;; *) fail "18: local changed set is missing $want:
$got" ;; esac
done
case "$got" in *ignored*) fail "18: an IGNORED file must not enter the changed set:
$got" ;; esac
echo "PASS: 18 the local changed set unions committed, staged, unstaged and untracked (never ignored) paths"

# --- 19. no resolvable base -> non-zero (caller degrades to the FULL set) ----
# The one degradation that matters here: with no default-branch base, the
# committed half of the worker's change is invisible. Returning the
# working-tree half alone would be a SILENT NARROWING — the exact class this
# lib's four defenses exist for — so it must fail instead.
ORPHAN="$TMP/orphan"
mkdir -p "$ORPHAN"
git -C "$ORPHAN" init -q
git -C "$ORPHAN" config user.email t@example.com
git -C "$ORPHAN" config user.name t
git -C "$ORPHAN" checkout -qb sidetrack 2>/dev/null || true
echo x >"$ORPHAN/x.txt"
git -C "$ORPHAN" add -A && git -C "$ORPHAN" commit -qm x
if gate_selection_local_changed "$ORPHAN" >/dev/null 2>"$TMP/err19"; then
  fail "19: a checkout with no default-branch base must NOT report a changed set"
fi
case "$(cat "$TMP/err19")" in *merge-base*) : ;; *) fail "19: the failure should name the missing merge-base (got: $(cat "$TMP/err19"))" ;; esac
echo "PASS: 19 an unresolvable default-branch base fails loudly instead of narrowing on the working tree alone"

# --- 20. not a git checkout -> non-zero, named ------------------------------
NOTREPO="$TMP/notrepo"
mkdir -p "$NOTREPO"
if ( cd "$NOTREPO" && gate_selection_local_changed "$NOTREPO" >/dev/null 2>"$TMP/err20" ); then
  fail "20: a non-repo directory must not report a changed set"
fi
echo "PASS: 20 a non-git directory fails instead of reporting an empty (= narrowing) changed set"

# --- 21. the REAL gate-paths.tsv: depth-0 new-surface scripts select the
# check-surface and exec-bit registry validators (temperloop#1931) ----------
# The generic new-surface globs #1931 added are only useful if they also
# match a DEPTH-0 candidate (`workflows/scripts/validate-zzz.sh`), not just a
# nested one — `**/` needs an explicit depth-0 twin under this matcher (see
# gate-paths.tsv's own header note). Prove it against the REAL map, not a
# synthetic fixture, with a mix of depth-0 and nested new-surface paths.
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
REAL_MAP="$REPO_ROOT/workflows/scripts/config/gate-paths.tsv"
[ -f "$REAL_MAP" ] || fail "21: real gate-paths.tsv not found at $REAL_MAP"
REAL_GATES='bash workflows/scripts/validate-check-surface-degenerate-coverage.sh
bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh
bash workflows/scripts/validate-exec-bit-registry.sh
bash workflows/scripts/tests/test_exec_bit_registry.sh'
for new_path in \
  workflows/scripts/validate-zzz.sh \
  workflows/scripts/tests/test_zzz.sh \
  workflows/scripts/config/check-zzz.sh
do
  reset_env
  QUALITY_GATES_SCOPE=diff
  GATE_SELECTION_MAP_FILE="$REAL_MAP"
  GATE_SELECTION_ALL_GATES="$REAL_GATES"
  GATE_SELECTION_CHANGED="$new_path"
  gate_selection_resolve
  [ "$GATE_SELECTION_MODE" = "diff" ] || fail "21 ($new_path): expected a diff-scoped run against the real map (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
  [ "$GATE_SELECTION_SELECTED" = "$REAL_GATES" ] || fail "21 ($new_path): a brand-new candidate-shaped script must select all four check-surface/exec-bit registry-validator gates, got:
$GATE_SELECTION_SELECTED"
done
echo "PASS: 21 a brand-new check-*/validate-*/test_* script (depth-0 and nested) selects the check-surface and exec-bit registry validators against the real gate-paths.tsv"

# --- 22. a REGISTRATION-ONLY quality-gates.sh diff selects the registry
# validators instead of the ALL escalation (temperloop#1933) ----------------
# scripts/quality-gates.sh is on the ALL row, so adding ONE gate line escalated
# the whole run to the full ~110-gate set. A registration ADDS a gate; it cannot
# change what an existing gate runs. gate-selection.sh therefore reads the diff
# and, only when nothing was removed and every added line is a registration (or
# a comment/blank riding along), skips the ALL row FOR THAT PATH.
#
# Both shapes are proven here against the REAL gate-paths.tsv, because the
# narrowing is only correct if the map really routes scripts/quality-gates.sh to
# the registry validators: a synthetic fixture would prove the code path and
# hide a missing row. 22a is the registration-only shape; 22b/22c/22d are the
# "any other edit" shapes that must KEEP the full escalation.
REG_GATES='bash workflows/scripts/config/check-gate-paths.sh
bash workflows/scripts/config/tests/test_check_gate_paths.sh
bash workflows/scripts/validate-check-surface-degenerate-coverage.sh
bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh
bash workflows/scripts/config/check-setting-registry.sh
bash workflows/scripts/validate-feature-docs.sh
bash workflows/scripts/validate-exec-bit-registry.sh
bash workflows/scripts/tests/test_exec_bit_registry.sh
make test-kernel-manifest
make test-env-hygiene-report
bash workflows/scripts/tests/test_ready_pr_sweep.sh'
# Everything above except the last two: the last-but-one is the CONTROL (a real,
# mapped gate no quality-gates.sh path reaches, so narrowing must leave it out)
# and the last is the gate the fixture diff REGISTERS.
REG_CONTROL='make test-env-hygiene-report'
REG_NEW='bash workflows/scripts/tests/test_ready_pr_sweep.sh'

reg_env() {
  reset_env
  QUALITY_GATES_SCOPE=diff
  GATE_SELECTION_MAP_FILE="$REAL_MAP"
  GATE_SELECTION_ALL_GATES="$REG_GATES"
  GATE_SELECTION_CHANGED='scripts/quality-gates.sh'
}

# 22a — nothing removed, added lines are a comment plus one registration.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,3 @@ KERNEL_GATES+=("bash workflows/scripts/lib/tests/test_gate_selection.sh")
+
+# A brand-new gate, registered the ordinary way (temperloop#1933 fixture).
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22a: a registration-only quality-gates.sh diff must NOT escalate (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_REASON" in *REGISTRATION-ONLY*) : ;; *) fail "22a: the reason must SAY the ALL escalation was declined (got: $GATE_SELECTION_REASON)" ;; esac
for want in \
  'bash workflows/scripts/config/check-gate-paths.sh' \
  'bash workflows/scripts/config/tests/test_check_gate_paths.sh' \
  'bash workflows/scripts/validate-check-surface-degenerate-coverage.sh' \
  'bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh' \
  'bash workflows/scripts/config/check-setting-registry.sh' \
  'bash workflows/scripts/validate-feature-docs.sh' \
  'bash workflows/scripts/validate-exec-bit-registry.sh' \
  'bash workflows/scripts/tests/test_exec_bit_registry.sh' \
  'make test-kernel-manifest'
do
  case "$GATE_SELECTION_SELECTED" in *"$want"*) : ;; *) fail "22a: the registry validator '$want' must be selected, got:
$GATE_SELECTION_SELECTED" ;; esac
done
case "$GATE_SELECTION_SELECTED" in *"$REG_NEW"*) : ;; *) fail "22a: the NEWLY REGISTERED gate must run on the PR that adds it, got:
$GATE_SELECTION_SELECTED" ;; esac
case "$GATE_SELECTION_SELECTED" in *"$REG_CONTROL"*) fail "22a: narrowing must still LEAVE OUT an unrelated mapped gate ($REG_CONTROL), got:
$GATE_SELECTION_SELECTED" ;; esac
case "$GATE_SELECTION_SKIPPED" in *"$REG_CONTROL"*) : ;; *) fail "22a: the skipped list must NAME the unrelated gate (got: $GATE_SELECTION_SKIPPED)" ;; esac
echo "PASS: 22a a registration-only quality-gates.sh diff selects the registry validators plus the newly registered gate, not the ALL escalation"

# 22b — ANY removed line means the edit is not a pure registration. This is the
# general case the exception must not weaken: an edited or deleted gate line can
# change what an EXISTING gate runs, which is exactly what the ALL row guards.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919 +1919,2 @@ KERNEL_GATES+=("bash a.sh")
-KERNEL_GATES+=("bash workflows/scripts/lib/tests/test_gate_selection.sh")
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22b: a diff that REMOVES a line must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_REASON" in *"ALL escalation"*) : ;; *) fail "22b: the reason should name the ALL escalation (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 22b a quality-gates.sh diff with a removed line keeps the full escalation"

# 22c — an added line that is not a registration (here: real logic) escalates.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,2 @@ KERNEL_GATES+=("bash a.sh")
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
+QG_BUDGET_SECS=1
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22c: a non-registration added line must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22c a quality-gates.sh diff mixing real logic into the additions keeps the full escalation"

# 22d — comments and blanks alone are NOT a registration. The exception exists
# for registering a gate, so a diff with no registration in it escalates rather
# than narrowing on the strength of "well, nothing executable changed".
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,2 @@ KERNEL_GATES+=("bash a.sh")
+# Just a comment.
+
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22d: a comment-only diff must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22d a comment-only quality-gates.sh diff keeps the full escalation"

# 22e — a splat registration (`+=("${ARRAY[@]}")`) names gates this probe cannot
# resolve, so it must NOT be read as a narrowable registration.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920 @@ KERNEL_GATES+=("bash a.sh")
+KERNEL_GATES+=("${SOME_OTHER_GATES[@]}")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22e: a splat registration must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22e a splat registration, whose gate names are unknowable, keeps the full escalation"

# 22f — no readable diff (no seam, no resolvable base) escalates. The probe
# fails CLOSED: an unreadable diff is not evidence that nothing was removed.
reg_env
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22f: an unreadable quality-gates.sh diff must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22f an unreadable quality-gates.sh diff fails closed to the full escalation"

# 22g — END TO END against a REAL git repo, no fixture seam. 22a-22f drive the
# classifier through GATE_SELECTION_DIFF_TEXT, which leaves the half that
# actually produces the diff (_gs_qg_diff: base resolution, `<base>...HEAD`
# unioned with the working tree) unproven. Here the registration is a real
# commit, the base is a real SHA, and git renders the diff. Also covers the
# mid-work shape the /build worker hits: an UNCOMMITTED second registration.
REG_REPO="$TMP/regrepo"
mkdir -p "$REG_REPO/scripts"
git -C "$REG_REPO" init -q
git -C "$REG_REPO" config user.email t@example.com
git -C "$REG_REPO" config user.name t
printf 'KERNEL_GATES=()\nKERNEL_GATES+=("make test-kernel-manifest")\n' >"$REG_REPO/scripts/quality-gates.sh"
git -C "$REG_REPO" add -A && git -C "$REG_REPO" commit -qm base
REG_BASE="$(git -C "$REG_REPO" rev-parse HEAD)"
{
  printf '\n# A new gate, registered the ordinary way.\n'
  printf 'KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")\n'
} >>"$REG_REPO/scripts/quality-gates.sh"
git -C "$REG_REPO" add -A && git -C "$REG_REPO" commit -qm register
# ...and one more, still uncommitted, as a mid-work worker would have it.
printf 'KERNEL_GATES+=("make test-env-hygiene-report")\n' >>"$REG_REPO/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO"
GATE_SELECTION_BASE="$REG_BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22g: a REAL registration-only commit must not escalate (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
for want in "$REG_NEW" "$REG_CONTROL" 'bash workflows/scripts/validate-exec-bit-registry.sh'; do
  case "$GATE_SELECTION_SELECTED" in *"$want"*) : ;; *) fail "22g: expected '$want' in the selection, got:
$GATE_SELECTION_SELECTED" ;; esac
done
echo "PASS: 22g a real registration-only diff (committed + uncommitted halves) narrows against a real git tree"

# 22h — the same real repo, with a line REMOVED in the working tree. The
# uncommitted half must be able to veto on its own, or a worker could delete a
# gate mid-work and still get the narrow run.
printf 'KERNEL_GATES=()\nKERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")\n' >"$REG_REPO/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO"
GATE_SELECTION_BASE="$REG_BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22h: an UNCOMMITTED removal must still keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22h a removal in the uncommitted half alone still keeps the full escalation"


echo "OK — gate-selection.sh: all cases passed"
