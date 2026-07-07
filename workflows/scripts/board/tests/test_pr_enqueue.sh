#!/usr/bin/env bash
#
# Fixture-replay tests for pr-enqueue.sh. Zero network: the script runs in a
# throwaway git repo (real `git` for origin parsing) with its `gh` calls routed
# through the PR_ENQUEUE_GH seam to a fake `gh` that logs argv and replays
# canned output. Asserts the three things #534 is about:
#   1. a mismatched-casing/host origin is CANONICALIZED and set as the gh default
#      before the PR is created;
#   2. the enqueue is a BARE `gh pr merge <n>` — never --merge/--squash/--rebase;
#   3. the queued state is CONFIRMED (and a confirm miss fails non-zero).
#
# Org/repo names here are deliberately GENERIC placeholders (Acme/widget) — the
# helper is repo-agnostic, so the fixtures carry no real org identity (kept out
# of the kernel by the personal-token denylist gate).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pr-enqueue.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-pr-enqueue-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- a fake gh: logs argv to $GH_LOG, dispatches by subcommand ----------------
FAKE_GH="$TMP/fake-gh"
cat >"$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
# Fake gh. Env: GH_LOG (argv transcript), GH_FULLNAME (canonical .full_name),
# GH_PR_URL (created PR url), GH_QUEUED (true|false), GH_MERGED (true|false),
# GH_CREATE_EXIT (0|nonzero), GH_CREATE_OUT (override create output).
printf 'gh ' >>"$GH_LOG"; printf '%q ' "$@" >>"$GH_LOG"; printf '\n' >>"$GH_LOG"
sub="${1:-}"; sub2="${2:-}"
if [ "$sub" = "api" ] && [ "$sub2" = "graphql" ]; then
  printf '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":%s,"isInMergeQueue":%s,"mergeQueueEntry":{"state":"QUEUED","position":1}}}}}\n' \
    "${GH_MERGED:-false}" "${GH_QUEUED:-true}"
  exit 0
fi
if [ "$sub" = "api" ]; then
  # api repos/<owner>/<repo> --jq .full_name
  printf '%s\n' "${GH_FULLNAME:-Acme/widget}"
  exit 0
fi
if [ "$sub" = "repo" ] && [ "$sub2" = "set-default" ]; then exit 0; fi
if [ "$sub" = "pr" ] && [ "$sub2" = "create" ]; then
  if [ -n "${GH_CREATE_OUT:-}" ]; then printf '%s\n' "$GH_CREATE_OUT"; else printf '%s\n' "${GH_PR_URL:-https://github.com/Acme/widget/pull/42}"; fi
  exit "${GH_CREATE_EXIT:-0}"
fi
if [ "$sub" = "pr" ] && [ "$sub2" = "merge" ]; then
  # bare enqueue: silent, exit 0
  exit "${GH_MERGE_EXIT:-0}"
fi
echo "fake-gh: unhandled: $*" >&2
exit 3
EOF
chmod +x "$FAKE_GH"

# --- a throwaway git repo with a MISMATCHED-CASING/host origin ----------------
make_repo() {  # <origin-url>
  local d; d="$(mktemp -d "$TMP/repo-XXXXXX")"
  git -C "$d" init -q
  git -C "$d" remote add origin "$1"
  printf '%s' "$d"
}

run() {  # <repo-dir> ; extra env via caller; args after
  local repo="$1"; shift
  ( cd "$repo" \
    && PR_ENQUEUE_GH="$FAKE_GH" PR_ENQUEUE_CONFIRM_INTERVAL=0 PR_ENQUEUE_CONFIRM_RETRIES=2 \
       GH_LOG="$GH_LOG" GH_FULLNAME="$GH_FULLNAME" GH_QUEUED="${GH_QUEUED:-true}" GH_MERGED="${GH_MERGED:-false}" \
       GH_CREATE_EXIT="${GH_CREATE_EXIT:-0}" GH_CREATE_OUT="${GH_CREATE_OUT:-}" GH_MERGE_EXIT="${GH_MERGE_EXIT:-0}" \
       GH_PR_URL="${GH_PR_URL:-https://github.com/Acme/widget/pull/42}" \
       bash "$SCRIPT" "$@" )
}

# =============================================================================
# Case 1: mismatched-casing origin → canonicalize + set-default + bare enqueue
#   origin repo-name casing (Widget) differs from canonical (widget).
# =============================================================================
GH_LOG="$TMP/log1"; : >"$GH_LOG"
GH_FULLNAME="Acme/widget"; GH_QUEUED=true; GH_MERGED=false
REPO="$(make_repo "https://github.com/Acme/Widget.git")"
out="$(run "$REPO" --title "Fix thing" --body "b")" || fail "1: exit non-zero: $out"

grep -qE '^gh api repos/Acme/Widget ' "$GH_LOG" \
  || fail "1: did not canonicalize via 'gh api repos/Acme/Widget' ($(cat "$GH_LOG"))"
grep -qE "^gh repo set-default Acme/widget " "$GH_LOG" \
  || fail "1: did not set gh default to canonical Acme/widget"
grep -qE '^gh pr create ' "$GH_LOG" || fail "1: no pr create"
# The enqueue must be BARE — assert the merge line carries NO method flag.
merge_line="$(grep -E '^gh pr merge ' "$GH_LOG" || true)"
[ -n "$merge_line" ] || fail "1: no pr merge (enqueue) call"
if grep -qE -- '--merge|--squash|--rebase|--auto' <<<"$merge_line"; then
  fail "1: enqueue was NOT bare — carried a method flag: $merge_line"
fi
grep -qE '^gh api graphql ' "$GH_LOG" || fail "1: no confirm graphql call"
grep -q 'enqueued in the merge queue' <<<"$out" || fail "1: output did not confirm queued: $out"
pass "1: mismatched-casing origin → canonicalized, set-default, bare enqueue, confirmed"

# =============================================================================
# Case 2: confirm MISS (isInMergeQueue false, not merged) → non-zero + message
# =============================================================================
GH_LOG="$TMP/log2"; : >"$GH_LOG"
GH_FULLNAME="Acme/widget"; GH_QUEUED=false; GH_MERGED=false
REPO="$(make_repo "git@github.com:Acme/widget.git")"
if out="$(run "$REPO" --title "T" --body "b" 2>&1)"; then
  fail "2: expected non-zero when queue state cannot be confirmed; got: $out"
fi
grep -q 'could NOT be confirmed in the merge queue' <<<"$out" \
  || fail "2: missing clear not-confirmed message: $out"
pass "2: unconfirmed enqueue exits non-zero with a clear message"

# =============================================================================
# Case 3: SSH origin parses to owner/repo (no scheme, git@host:owner/repo),
#   with an owner-casing mismatch (acme → canonical Acme).
# =============================================================================
GH_LOG="$TMP/log3"; : >"$GH_LOG"
GH_FULLNAME="Acme/gadget"; GH_QUEUED=true; GH_MERGED=false
GH_PR_URL="https://github.com/Acme/gadget/pull/7"
REPO="$(make_repo "git@github.com:acme/Gadget.git")"
out="$(run "$REPO" --fill)" || fail "3: exit non-zero: $out"
grep -qE '^gh api repos/acme/Gadget ' "$GH_LOG" \
  || fail "3: SSH origin not parsed to owner/repo ($(cat "$GH_LOG"))"
grep -qE -- '--fill' "$GH_LOG" || fail "3: --fill not forwarded to gh pr create"
unset GH_PR_URL
pass "3: SSH origin parsed; --fill forwarded"

# =============================================================================
# Case 4: --json emits a machine-readable QUEUED record
# =============================================================================
GH_LOG="$TMP/log4"; : >"$GH_LOG"
GH_FULLNAME="Acme/widget"; GH_QUEUED=true; GH_MERGED=false
REPO="$(make_repo "https://github.com/Acme/widget.git")"
out="$(run "$REPO" --title "T" --body "b" --json)" || fail "4: exit non-zero: $out"
jq -e '.outcome=="QUEUED" and .pr_number==42 and .repo=="Acme/widget"' >/dev/null <<<"$out" \
  || fail "4: json record wrong: $out"
pass "4: --json emits a QUEUED record with pr_number and repo"

# =============================================================================
# Case 5: already-existing PR is adopted, then enqueued
# =============================================================================
GH_LOG="$TMP/log5"; : >"$GH_LOG"
GH_FULLNAME="Acme/widget"; GH_QUEUED=true; GH_MERGED=false
GH_CREATE_EXIT=1
GH_CREATE_OUT="a pull request for branch \"feat/x\" into branch \"main\" already exists:
https://github.com/Acme/widget/pull/99"
REPO="$(make_repo "https://github.com/Acme/widget.git")"
out="$(run "$REPO" --title "T" --body "b")" || fail "5: exit non-zero: $out"
grep -q 'adopted existing PR #99' <<<"$out" || fail "5: did not adopt existing PR: $out"
grep -qE '^gh pr merge 99 ' "$GH_LOG" || fail "5: did not enqueue adopted PR #99"
unset GH_CREATE_EXIT GH_CREATE_OUT
pass "5: existing PR adopted and enqueued"

echo
echo "PASS: all pr-enqueue tests passed"
