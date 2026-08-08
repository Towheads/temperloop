#!/usr/bin/env bash
#
# Tests for workflows/scripts/promote/push-testbed-branch.sh — the mechanical
# half of `/promote` (temperloop#1233, epic #1117 Produces 6).
#
# THIS SUITE IS THE POINT OF THE SPLIT. ADR 0023 splits a capability into a
# judgment half (a slash command) and a mechanical half (a script) precisely so
# the mechanical half can be asserted against structurally — a test cannot
# assert anything about a prose step in a markdown spec. So the refs guarantee
# promotion needs is proven HERE, by this script's OWN test, and is explicitly
# NOT inherited from proposal-pr.sh's equivalent guarantee (which holds for a
# different mechanism: proposal-pr.sh rebuilds a branch off the base tip from a
# files manifest, which would squash away exactly the commits promotion exists
# to carry).
#
# Zero network throughout. The target "repository" is a real local bare git
# repo reached through the `--target-url` seam, every `gh` touch point is a
# fake `gh` on PATH answering from env, and Part G additionally puts a logging
# `git` wrapper on PATH so the refspec assertion reads the script's ACTUAL
# invocations rather than trusting its source.
#
#   Part A  argument refusals (the target is never inferred)
#   Part B  the source_kind refusal, READ from the artifact record
#   Part C  the unrecorded-testbed refusal and its opt-in escape
#   Part D  the access precondition, checked in pre-flight with a fallback
#   Part E  pre-flight / --dry-run writes nothing
#   Part F  a real push carrying real commits AND real authorship
#   Part G  THE refs assertion: only refs/heads/<branch>, never the default
#   Part H  branch == base, and an already-existing branch, are refused
#   Part I  every opened pull request carries the one-line provenance note
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/push-testbed-branch.sh"
REAL_GIT="$(command -v git)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/promote-push-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$STATE/temperloop" "$BIN"

# --- fake gh ---------------------------------------------------------------
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_ARGV_LOG:-}" ]; then
  for a in "$@"; do printf '%s\n' "$a" >> "$GH_ARGV_LOG"; done
  printf '%s\n' '--END--' >> "$GH_ARGV_LOG"
fi
case "$1" in
  auth) [ "${FAKE_GH_AUTH:-ok}" = "ok" ] || exit 1; exit 0 ;;
  api)
    if [ "${FAKE_GH_API_FAIL:-0}" = "1" ]; then echo "gh: HTTP 404" >&2; exit 1; fi
    printf '%s\n' "${FAKE_GH_PUSH_PERM:-true}"; exit 0 ;;
  pr)
    if [ "${FAKE_GH_PR_FAIL:-0}" = "1" ]; then echo "gh: pr create failed" >&2; exit 1; fi
    printf 'https://github.com/acme/proj/pull/7\n'; exit 0 ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# --- logging git wrapper (Part G) ------------------------------------------
cat > "$BIN/git" <<GIT
#!/usr/bin/env bash
if [ -n "\${GIT_LOG:-}" ]; then printf '%s\n' "\$*" >> "\$GIT_LOG"; fi
exec "$REAL_GIT" "\$@"
GIT
chmod +x "$BIN/git"

# --- fixtures --------------------------------------------------------------
# <name> -> $TMP/<name>/{target.git, tb}. `target.git` is the reader's REAL
# repository (bare, default branch `main`, holding one original commit by
# "Original Author"); `tb` is the testbed — a genuine clone of it, sharing
# that history, plus one commit authored by "Pipeline Bot" standing in for
# what the pipeline did inside the testbed.
make_fixture() {
  local d="$TMP/$1"
  mkdir -p "$d"
  "$REAL_GIT" init -q --bare "$d/target.git"
  "$REAL_GIT" -C "$d/target.git" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" init -q "$d/seed"
  "$REAL_GIT" -C "$d/seed" checkout -q -b main
  echo base > "$d/seed/README.md"
  "$REAL_GIT" -C "$d/seed" add -A
  "$REAL_GIT" -C "$d/seed" -c user.name="Original Author" -c user.email=orig@example.com commit -qm "base commit"
  "$REAL_GIT" -C "$d/seed" push -q "$d/target.git" main:main
  "$REAL_GIT" clone -q "$d/target.git" "$d/tb"
  "$REAL_GIT" -C "$d/tb" remote set-url origin https://github.com/acme/proj-testbed.git
  echo fix > "$d/tb/fix.txt"
  "$REAL_GIT" -C "$d/tb" add -A
  "$REAL_GIT" -C "$d/tb" -c user.name="Pipeline Bot" -c user.email=bot@example.com commit -qm "fix: what the pipeline did"
}

# <source_kind> <source_repo|null> <promotable>
write_record() {
  local kind="$1" repo="$2" promotable="$3"
  if [ "$repo" = "null" ]; then repo=null; else repo="\"$repo\""; fi
  cat > "$STATE/temperloop/testbed-record.json" <<EOF
{
  "schema_version": 1,
  "testbeds": {
    "acme/proj-testbed": [
      {
        "id": "t1",
        "created_at": "2026-08-08T00:00:00Z",
        "testbed_repo": "acme/proj-testbed",
        "source_kind": "$kind",
        "source_repo": $repo,
        "promotable": $promotable,
        "artifacts": { "repo_created": true, "mirror_pushed": true, "issues_copied": true }
      }
    ]
  }
}
EOF
}

clear_record() { rm -f "$STATE/temperloop/testbed-record.json"; }

OUT=""; RC=0
# The fake gh answers from these three; each scenario sets them explicitly and
# resets them afterwards, so no scenario inherits a previous one's arrangement.
FAKE_GH_AUTH=ok
FAKE_GH_PUSH_PERM=true
FAKE_GH_API_FAIL=0
run() {  # run <script args...>
  set +e
  OUT="$(PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" \
    FAKE_GH_AUTH="$FAKE_GH_AUTH" \
    FAKE_GH_PUSH_PERM="$FAKE_GH_PUSH_PERM" \
    FAKE_GH_API_FAIL="$FAKE_GH_API_FAIL" \
    bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

# =============================================================================
# Part A -- argument refusals. The target repository is NEVER inferred.
# =============================================================================
make_fixture a
write_record mirror-from-repo acme/proj true

run push --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "A1: a run with no --to should refuse"
case "$OUT" in *"never infers the target repository"*) ;; *) fail "A1: refusal should say the target is never inferred (got: $OUT)" ;; esac
echo "PASS: A1 refuses without an explicit --to (the target is never inferred from cwd)"

run push --to acme/proj --branch refs/heads/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "A2: a refs/-prefixed --branch should be refused"
echo "PASS: A2 refuses a --branch that is not a plain branch name"

run push --to not-a-slug --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "A3: a malformed --to should be refused"
echo "PASS: A3 refuses a --to that is not owner/name"

# =============================================================================
# Part B -- the source_kind refusal, keyed on the artifact record's own field.
# =============================================================================
write_record materialize-from-seed null false
run preflight --to acme/proj --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "B1: a materialize-from-seed testbed must be refused"
case "$OUT" in *"materialize-from-seed"*) ;; *) fail "B1: refusal must name the recorded source_kind (got: $OUT)" ;; esac
case "$OUT" in *"no original to promote to"*) ;; *) fail "B1: refusal must say WHY — there is no original to promote to (got: $OUT)" ;; esac
echo "PASS: B1 refuses a materialize-from-seed testbed, naming source_kind and why"

# The refusal is READ, not inferred: a record that says mirror-from-repo but
# promotable=false is still refused, and on the record's own say-so.
write_record mirror-from-repo acme/proj false
run preflight --to acme/proj --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "B2: promotable=false must be refused"
case "$OUT" in *"promotable=false"*) ;; *) fail "B2: refusal must cite the recorded promotable field (got: $OUT)" ;; esac
echo "PASS: B2 honours the record's promotable=false independently of source_kind"

# =============================================================================
# Part C -- an unrecorded testbed, and the explicit escape.
# =============================================================================
clear_record
run preflight --to acme/proj --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
[ "$RC" -ne 0 ] || fail "C1: an unrecorded testbed should be refused by default"
case "$OUT" in *"no artifact record"*) ;; *) fail "C1: refusal must name the missing record (got: $OUT)" ;; esac
echo "PASS: C1 refuses when no artifact record exists (the source-kind check cannot run)"

run preflight --to acme/proj --branch promote/x --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git" --allow-unrecorded
[ "$RC" -eq 0 ] || fail "C2: --allow-unrecorded should proceed (got rc=$RC: $OUT)"
case "$OUT" in *"could NOT be evaluated"*) ;; *) fail "C2: the escape must say loudly that the check was skipped (got: $OUT)" ;; esac
echo "PASS: C2 --allow-unrecorded proceeds and says loudly that the check was skipped"

# =============================================================================
# Part D -- the access precondition, checked in PRE-FLIGHT with a fallback.
# =============================================================================
write_record mirror-from-repo acme/proj true

FAKE_GH_PUSH_PERM=false
run preflight --to acme/proj --branch promote/x \
  --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
FAKE_GH_PUSH_PERM=true
[ "$RC" -ne 0 ] || fail "D1: no push permission on the target must refuse"
case "$OUT" in *"cannot push to acme/proj"*) ;; *) fail "D1: refusal must name the missing permission (got: $OUT)" ;; esac
case "$OUT" in *"gh repo fork"*) ;; *) fail "D1: refusal must document the fork fallback (got: $OUT)" ;; esac
echo "PASS: D1 pre-flight refuses on no push access and documents the fork fallback"

FAKE_GH_AUTH=no
run preflight --to acme/proj --branch promote/x \
  --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
FAKE_GH_AUTH=ok
[ "$RC" -ne 0 ] || fail "D2: unauthenticated gh must refuse"
case "$OUT" in *"gh auth login"*) ;; *) fail "D2: refusal must name the remedy (got: $OUT)" ;; esac
echo "PASS: D2 pre-flight refuses when gh is unauthenticated, naming the remedy"

FAKE_GH_API_FAIL=1
run preflight --to acme/proj --branch promote/x \
  --testbed-dir "$TMP/a/tb" --target-url "$TMP/a/target.git"
FAKE_GH_API_FAIL=0
[ "$RC" -ne 0 ] || fail "D3: an unreadable target must refuse"
case "$OUT" in *"fork"*) ;; *) fail "D3: refusal must document the fallback (got: $OUT)" ;; esac
echo "PASS: D3 pre-flight refuses when the target's permissions cannot be read"

# =============================================================================
# Part E -- pre-flight / --dry-run writes nothing.
# =============================================================================
make_fixture e
before="$("$REAL_GIT" -C "$TMP/e/target.git" for-each-ref --format='%(refname) %(objectname)' | sort)"
run push --to acme/proj --branch promote/x --testbed-dir "$TMP/e/tb" --target-url "$TMP/e/target.git" --dry-run
[ "$RC" -eq 0 ] || fail "E1: --dry-run should succeed (got rc=$RC: $OUT)"
after="$("$REAL_GIT" -C "$TMP/e/target.git" for-each-ref --format='%(refname) %(objectname)' | sort)"
[ "$before" = "$after" ] || fail "E1: --dry-run changed refs on the target"
case "$OUT" in *"nothing was pushed"*) ;; *) fail "E1: --dry-run must say nothing was pushed (got: $OUT)" ;; esac
echo "PASS: E1 --dry-run runs pre-flight and leaves the target's refs untouched"

# =============================================================================
# Part F -- a real push, carrying the testbed's REAL commits and authorship.
# =============================================================================
make_fixture f
tb_sha="$("$REAL_GIT" -C "$TMP/f/tb" rev-parse HEAD)"
main_before="$("$REAL_GIT" -C "$TMP/f/target.git" rev-parse refs/heads/main)"

run push --to acme/proj --branch promote/carried-work --testbed-dir "$TMP/f/tb" --target-url "$TMP/f/target.git"
[ "$RC" -eq 0 ] || fail "F1: the push should succeed (got rc=$RC: $OUT)"

pushed="$("$REAL_GIT" -C "$TMP/f/target.git" rev-parse refs/heads/promote/carried-work)"
[ "$pushed" = "$tb_sha" ] || fail "F1: the pushed branch tip ($pushed) is not the testbed's own commit ($tb_sha)"
echo "PASS: F1 pushes the testbed's ACTUAL commit object, not a rebuilt one"

author="$("$REAL_GIT" -C "$TMP/f/target.git" log -1 --format='%an <%ae>' refs/heads/promote/carried-work)"
[ "$author" = "Pipeline Bot <bot@example.com>" ] \
  || fail "F2: authorship was not preserved (got: $author)"
subject="$("$REAL_GIT" -C "$TMP/f/target.git" log -1 --format='%s' refs/heads/promote/carried-work)"
[ "$subject" = "fix: what the pipeline did" ] || fail "F2: the commit message was not preserved (got: $subject)"
echo "PASS: F2 preserves the testbed's authorship and commit message verbatim"

count="$("$REAL_GIT" -C "$TMP/f/target.git" rev-list --count refs/heads/main..refs/heads/promote/carried-work)"
[ "$count" = "1" ] || fail "F3: expected 1 promoted commit on top of the shared base, got $count"
echo "PASS: F3 the promoted branch shares history with the original (1 commit ahead, not a squashed import)"

main_after="$("$REAL_GIT" -C "$TMP/f/target.git" rev-parse refs/heads/main)"
[ "$main_before" = "$main_after" ] || fail "F4: the target's default branch moved"
echo "PASS: F4 the target's default branch is untouched by the push"

# It does NOT delegate to the proposal-PR generator — that generator rebuilds
# the branch off the base tip from a files manifest, which is exactly what
# would discard the authorship F2 just proved survives. (The only mentions of
# it in this script are the header's own "why not" note, which is a comment.)
if grep -Eq '^[[:space:]]*[^#]*(bash|sh|exec|source|\.)[[:space:]][^#]*proposal-pr\.sh' "$SCRIPT"; then
  fail "F5: the script appears to execute proposal-pr.sh"
fi
echo "PASS: F5 the mechanism is its own — proposal-pr.sh is never invoked"

# =============================================================================
# Part G -- THE structural assertion, and this script's OWN, not an inherited
# one: every ref this script pushes is refs/heads/<branch>, and the target's
# default branch is never among them.
# =============================================================================
make_fixture g
LOG="$TMP/git-calls.log"
: > "$LOG"
set +e
OUT="$(PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" GIT_LOG="$LOG" \
  bash "$SCRIPT" push --to acme/proj --branch promote/carried-work \
  --testbed-dir "$TMP/g/tb" --target-url "$TMP/g/target.git" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "G0: the logged run should succeed (got rc=$RC: $OUT)"

push_lines="$(grep -E '(^| )push( |$)' "$LOG" || true)"
n="$(printf '%s\n' "$push_lines" | grep -c . || true)"
[ "$n" = "1" ] || fail "G1: expected exactly ONE git push invocation, got $n:
$push_lines"
echo "PASS: G1 the script issues exactly one git push"

case "$push_lines" in
  *"refs/promote/source:refs/heads/promote/carried-work"*) ;;
  *) fail "G2: the push refspec is not the explicit refs/heads/<branch> form: $push_lines" ;;
esac
echo "PASS: G2 the one push uses the explicit refs/promote/source:refs/heads/<branch> refspec"

for forbidden in --mirror --all --tags --force --delete --prune; do
  case "$push_lines" in
    *"$forbidden"*) fail "G3: the push carries $forbidden, which can move refs the caller never named: $push_lines" ;;
  esac
done
echo "PASS: G3 the push carries no --mirror / --all / --tags / --force / --delete / --prune"

# The default branch appears nowhere on the destination side of any refspec.
case "$push_lines" in
  *":refs/heads/main"* | *" main"* | *"HEAD:"*)
    fail "G4: a push refspec names the default branch: $push_lines" ;;
esac
echo "PASS: G4 no push refspec names the target's default branch"

# And the observable proof on the target itself.
[ "$("$REAL_GIT" -C "$TMP/g/target.git" rev-parse refs/heads/main)" \
  = "$("$REAL_GIT" -C "$TMP/g/seed" rev-parse HEAD)" ] \
  || fail "G5: the target's main moved during the promotion push"
refs_now="$("$REAL_GIT" -C "$TMP/g/target.git" for-each-ref --format='%(refname)' | sort | tr '\n' ' ')"
[ "$refs_now" = "refs/heads/main refs/heads/promote/carried-work " ] \
  || fail "G5: unexpected refs on the target after promotion: $refs_now"
echo "PASS: G5 the target ends with exactly its default branch plus the promoted branch"

# =============================================================================
# Part H -- branch == base, and an already-existing branch, are refused.
# =============================================================================
make_fixture h
run push --to acme/proj --branch main --testbed-dir "$TMP/h/tb" --target-url "$TMP/h/target.git"
[ "$RC" -ne 0 ] || fail "H1: pushing the base branch must be refused"
case "$OUT" in *"never pushes to acme/proj's default branch"*) ;; *) fail "H1: refusal must say so plainly (got: $OUT)" ;; esac
[ "$("$REAL_GIT" -C "$TMP/h/target.git" rev-parse refs/heads/main)" = "$("$REAL_GIT" -C "$TMP/h/seed" rev-parse HEAD)" ] \
  || fail "H1: main moved despite the refusal"
echo "PASS: H1 --branch equal to the target's base branch is refused up front"

run push --to acme/proj --branch promote/dup --testbed-dir "$TMP/h/tb" --target-url "$TMP/h/target.git"
[ "$RC" -eq 0 ] || fail "H2 setup: first push should succeed (got: $OUT)"
run push --to acme/proj --branch promote/dup --testbed-dir "$TMP/h/tb" --target-url "$TMP/h/target.git"
[ "$RC" -ne 0 ] || fail "H2: pushing onto an existing branch must be refused"
case "$OUT" in *"already exists on acme/proj"*) ;; *) fail "H2: refusal must name the existing branch (got: $OUT)" ;; esac
echo "PASS: H2 an existing refs/heads/<branch> on the target is refused, never force-pushed"

# =============================================================================
# Part I -- every opened pull request carries the one-line provenance note.
# =============================================================================
make_fixture i
ARGV="$TMP/gh-argv.log"
: > "$ARGV"
set +e
OUT="$(PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" GH_ARGV_LOG="$ARGV" \
  bash "$SCRIPT" push --to acme/proj --branch promote/pr-note \
  --testbed-dir "$TMP/i/tb" --target-url "$TMP/i/target.git" \
  --open-pr --pr-title "Promote the pipeline's fix" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "I0: the --open-pr run should succeed (got rc=$RC: $OUT)"

grep -Fxq -- '--head' "$ARGV" || fail "I1: gh pr create was not invoked with --head"
grep -Fxq -- 'promote/pr-note' "$ARGV" || fail "I1: gh pr create did not carry the promoted branch"
grep -Fxq -- 'main' "$ARGV" || fail "I1: gh pr create did not carry the base branch"
echo "PASS: I1 the pull request is opened from the promoted branch into the target's base"

grep -Fq 'Promoted from the temperloop evaluation testbed acme/proj-testbed' "$ARGV" \
  || fail "I2: the pull-request body carries no provenance note"
grep -Fq 'mirror-from-repo' "$ARGV" || fail "I2: the provenance note omits the recorded source kind"
echo "PASS: I2 the pull-request body carries the one-line provenance note"

# The note is the script's, not the caller's: a caller-supplied body does not
# replace it.
make_fixture j
: > "$ARGV"
set +e
OUT="$(PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" GH_ARGV_LOG="$ARGV" \
  bash "$SCRIPT" push --to acme/proj --branch promote/pr-note \
  --testbed-dir "$TMP/j/tb" --target-url "$TMP/j/target.git" \
  --open-pr --pr-body "Whatever the caller wanted to say." 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "I3: the --pr-body run should succeed (got rc=$RC: $OUT)"
grep -Fq 'Whatever the caller wanted to say.' "$ARGV" || fail "I3: the caller's body was dropped"
grep -Fq 'Promoted from the temperloop evaluation testbed' "$ARGV" \
  || fail "I3: a caller-supplied body suppressed the provenance note"
echo "PASS: I3 a caller-supplied body never suppresses the provenance note"

echo
echo "All push-testbed-branch.sh tests passed."
