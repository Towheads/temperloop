#!/usr/bin/env bash
#
# Tests for baseline-snapshot.sh — `temperloop baseline-snapshot` (foundation
# #766, Epic E "before/after value proof"). Zero real network — a fake `gh`
# on PATH (or none at all) drives every case against a scratch fixture git
# repo, mirroring the try.sh/init.sh test convention (see
# kernel/bin/subcommands/tests/test_try.sh, test_init.sh).
#
# Covers:
#   1. happy path: fake gh returns merged PRs + open issues; asserts schema
#      1, correct median/count arithmetic, and — the load-bearing consent
#      assertion — that no per-reviewer/per-author field (e.g. a login
#      name) ever appears anywhere in the emitted record, even though the
#      fake gh's raw reviews payload carries author info.
#   2. re-appendable: two runs produce two JSONL lines, not a rewrite.
#   3. .temperloop/.gitignore self-management: created on a cold repo,
#      idempotent on a repeat run (no duplicate "baseline.jsonl" line).
#   4. degrade paths, each still exit 0 with metrics.available=false and a
#      specific reason: no origin remote; gh absent from PATH; gh present
#      but unauthenticated.
#   5. cold repo (not even a git working tree): exit 0, gh_repo null.
#   6. CLI hygiene: an unknown arg is a usage error (exit 2); -h exits 0.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="$HERE/../baseline-snapshot.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/baseline-snapshot-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# --- fixture repo with an origin remote (no push needed — only
# `remote get-url origin` is ever read) ------------------------------------
REPO="$WORK/fixture-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin "git@github.com:test-owner/test-repo.git"

# --- fake gh: authenticated, returns two merged PRs (one reviewed, one
# not) and two open issues. Review payload deliberately carries an
# `author.login` field (the real gh shape) so test 1 can assert it never
# leaks into the record. -----------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    exit "${FAKE_AUTH_RC:-0}"
    ;;
  pr)
    case "$2" in
      list)
        cat <<'JSON'
[
  {"createdAt":"2026-05-01T00:00:00Z","mergedAt":"2026-05-03T00:00:00Z","reviews":[{"submittedAt":"2026-05-02T00:00:00Z","author":{"login":"alice-the-reviewer"}}]},
  {"createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-02T12:00:00Z","reviews":[]}
]
JSON
        exit 0
        ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        cat <<'JSON'
[
  {"createdAt":"2026-04-01T00:00:00Z"},
  {"createdAt":"2026-06-15T00:00:00Z"}
]
JSON
        exit 0
        ;;
    esac
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

NOW="2026-07-03T00:00:00Z"

# --- 1: happy path -----------------------------------------------------------
out="$(cd "$REPO" && PATH="$BIN:$PATH" BASELINE_SNAPSHOT_NOW="$NOW" bash "$SNAP")"
echo "$out" | grep -q "metrics available: true" || fail "stdout should report metrics available: true"

record="$(cd "$REPO" && tail -n1 .temperloop/baseline.jsonl)"
echo "$record" | jq empty || fail "record is not valid JSON"

[ "$(jq -r '.schema' <<<"$record")" = "1" ] || fail "schema should be 1"
[ "$(jq -r '.generated_at' <<<"$record")" = "$NOW" ] || fail "generated_at should honor BASELINE_SNAPSHOT_NOW"
[ "$(jq -r '.lookback_days' <<<"$record")" = "90" ] || fail "lookback_days should default to 90"
[ "$(jq -r '.repo.gh_repo' <<<"$record")" = "test-owner/test-repo" ] || fail "gh_repo should be inferred from origin"

[ "$(jq -r '.metrics.available' <<<"$record")" = "true" ] || fail "metrics.available should be true"
[ "$(jq -r '.metrics.reason' <<<"$record")" = "null" ] || fail "metrics.reason should be null when available"
[ "$(jq -r '.metrics.pr_throughput.merged_count' <<<"$record")" = "2" ] || fail "merged_count should be 2"
[ "$(jq -r '.metrics.time_to_merge_hours.median' <<<"$record")" = "42" ] || fail "time_to_merge_hours.median should be 42 ((48+36)/2)"
[ "$(jq -r '.metrics.time_to_merge_hours.sample_size' <<<"$record")" = "2" ] || fail "time_to_merge_hours.sample_size should be 2"
[ "$(jq -r '.metrics.review_latency_hours.median' <<<"$record")" = "24" ] || fail "review_latency_hours.median should be 24 (only 1 PR had a review)"
[ "$(jq -r '.metrics.review_latency_hours.sample_size' <<<"$record")" = "1" ] || fail "review_latency_hours.sample_size should be 1 (PR with no reviews excluded)"
[ "$(jq -r '.metrics.issue_backlog.open_count' <<<"$record")" = "2" ] || fail "issue_backlog.open_count should be 2"
[ "$(jq -r '.metrics.issue_backlog.median_age_days' <<<"$record")" = "55.5" ] || fail "issue_backlog.median_age_days should be 55.5 ((93+18)/2)"

# --- consent posture: NO identifying field anywhere in the record ----------
echo "$record" | grep -qi "alice" && fail "reviewer identity must never appear in the record (consent posture)"
echo "$record" | grep -qi "login" && fail "no 'login'-shaped field should appear anywhere in the record"

# --- 2: re-appendable ---------------------------------------------------------
lines_before="$(cd "$REPO" && wc -l < .temperloop/baseline.jsonl | tr -d ' ')"
(cd "$REPO" && PATH="$BIN:$PATH" BASELINE_SNAPSHOT_NOW="$NOW" bash "$SNAP" >/dev/null)
lines_after="$(cd "$REPO" && wc -l < .temperloop/baseline.jsonl | tr -d ' ')"
[ "$lines_after" -eq "$((lines_before + 1))" ] || fail "a second run should APPEND one more line, not rewrite the file"

# --- 3: .gitignore self-management, idempotent ------------------------------
[ -f "$REPO/.temperloop/.gitignore" ] || fail ".temperloop/.gitignore should be created"
grep -Fxq "baseline.jsonl" "$REPO/.temperloop/.gitignore" || fail ".gitignore should list baseline.jsonl"
gitignore_lines_before="$(wc -l < "$REPO/.temperloop/.gitignore" | tr -d ' ')"
(cd "$REPO" && PATH="$BIN:$PATH" BASELINE_SNAPSHOT_NOW="$NOW" bash "$SNAP" >/dev/null)
gitignore_lines_after="$(wc -l < "$REPO/.temperloop/.gitignore" | tr -d ' ')"
[ "$gitignore_lines_after" -eq "$gitignore_lines_before" ] || fail ".gitignore entry must be idempotent (no duplicate line)"

# --- 4a: degrade — no origin remote -----------------------------------------
NOREMOTE="$WORK/no-remote-repo"
mkdir -p "$NOREMOTE"
git -C "$NOREMOTE" init -q -b main
(cd "$NOREMOTE" && PATH="$BIN:$PATH" BASELINE_SNAPSHOT_NOW="$NOW" bash "$SNAP" >/dev/null)
rec4a="$(cd "$NOREMOTE" && tail -n1 .temperloop/baseline.jsonl)"
[ "$(jq -r '.metrics.available' <<<"$rec4a")" = "false" ] || fail "metrics.available should be false with no origin remote"
jq -e '.metrics.reason | test("owner/repo")' <<<"$rec4a" >/dev/null || fail "reason should mention owner/repo"
[ "$(jq -r '.repo.gh_repo' <<<"$rec4a")" = "null" ] || fail "gh_repo should be null with no origin remote"

# --- 4b: degrade — gh absent from PATH --------------------------------------
NOGHBIN="$WORK/no-gh-path"
mkdir -p "$NOGHBIN"
for tool in git jq sed awk grep sort mktemp date find cut printf cat sleep wc tr mkdir; do
  bin="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$bin" ] && ln -sf "$bin" "$NOGHBIN/$tool"
done
BASH_BIN="$(command -v bash)"
(cd "$REPO" && PATH="$NOGHBIN" BASELINE_SNAPSHOT_NOW="$NOW" "$BASH_BIN" "$SNAP" >/dev/null)
rec4b="$(cd "$REPO" && tail -n1 .temperloop/baseline.jsonl)"
[ "$(jq -r '.metrics.available' <<<"$rec4b")" = "false" ] || fail "metrics.available should be false with gh absent"
jq -e '.metrics.reason | test("gh CLI not found")' <<<"$rec4b" >/dev/null || fail "reason should name gh CLI absence"

# --- 4c: degrade — gh present but unauthenticated ---------------------------
(cd "$REPO" && PATH="$BIN:$PATH" FAKE_AUTH_RC=1 BASELINE_SNAPSHOT_NOW="$NOW" bash "$SNAP" >/dev/null)
rec4c="$(cd "$REPO" && tail -n1 .temperloop/baseline.jsonl)"
[ "$(jq -r '.metrics.available' <<<"$rec4c")" = "false" ] || fail "metrics.available should be false when gh is unauthenticated"
jq -e '.metrics.reason | test("not authenticated")' <<<"$rec4c" >/dev/null || fail "reason should mention gh not authenticated"

# --- 5: cold repo (not even a git working tree) -----------------------------
COLD="$WORK/cold-dir"
mkdir -p "$COLD"
(cd "$COLD" && PATH="$NOGHBIN" "$BASH_BIN" "$SNAP" >/dev/null)
[ -f "$COLD/.temperloop/baseline.jsonl" ] || fail "a cold (non-git) dir should still get a written record"
rec5="$(cd "$COLD" && tail -n1 .temperloop/baseline.jsonl)"
[ "$(jq -r '.repo.gh_repo' <<<"$rec5")" = "null" ] || fail "gh_repo should be null in a cold non-git dir"

# --- 6: CLI hygiene ------------------------------------------------------------
if bash "$SNAP" --bogus-flag >/dev/null 2>&1; then
  fail "an unknown arg should be a usage error (exit 2)"
fi
bash "$SNAP" -h >/dev/null || fail "-h should exit 0"

echo "OK: test_baseline_snapshot.sh"
