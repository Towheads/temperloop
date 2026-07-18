#!/usr/bin/env bash
#
# test_sandbox_dry_run_legs.sh — the install-surface dry-run legs
# (temperloop#263, "sandbox-core", ADR K164 D6): proves `temperloop init
# --dry-run` and `temperloop eject --dry-run` run green, hermetically, end
# to end through a REAL bootstrapped install — not just a direct
# `bash init.sh` invocation (bin/subcommands/tests/test_init.sh /
# test_eject.sh already cover that shape).
#
# Flow, entirely inside the sandbox (workflows/scripts/tests/lib/sandbox.sh):
#   1. sandbox_bootstrap_checkout this repo (its own committed HEAD) over a
#      file:// remote — the hermetic stand-in for the curl-pipe-sh newcomer
#      install — producing a real, working `temperloop` binary.
#   2. A throwaway TARGET repo (bare upstream + clone, same fixture idiom as
#      bin/subcommands/tests/test_init.sh's own new_fixture_repo) — the repo
#      a newcomer would run `temperloop init` against.
#   3. `temperloop init --dir TARGET --gh-repo acme/widget --no-network
#      --dry-run --yes-required-check --yes-labels` — the exact flag
#      combination test_init.sh's own test 1 already proves makes ZERO gh
#      calls (tree-only preview); asserted again here through the
#      bootstrapped dispatcher, not just the bare subcommand script.
#   4. `temperloop eject --dir TARGET --dry-run` — mirrors test_eject.sh's
#      own test 2 (zero gh calls, .foundation/config left untouched).
#   5. No-residue: the same real-HOME candidate-path check
#      workflows/scripts/tests/lib/tests/test_sandbox.sh's own test 5 uses.
#
# No network. No real HOME/XDG mutations at any point.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=workflows/scripts/tests/lib/sandbox.sh
source "$HERE/lib/sandbox.sh"

# Kernel-only: bootstraps this repo's install CLI from bin/bootstrap.sh, which
# exists only when the repo root IS the kernel. (#363)
sandbox_skip_if_composed_tree "test_sandbox_dry_run_legs.sh" "$REPO_ROOT"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

# assert_no_mutating_gh_calls LABEL — unlike test_init.sh/test_eject.sh
# (which invoke the subcommand script directly), this suite dispatches
# through the real `temperloop` CLI, whose prereq gate
# (bin/lib/common.sh: foundation_check_prereqs) makes exactly one
# read-only `gh auth status` call before EVERY dispatch — that call is
# inherent to using the real install surface, not a leak from
# init.sh/eject.sh's own dry-run logic. So the bar here is "no call other
# than that one read-only probe", not "zero calls of any kind".
assert_no_mutating_gh_calls() {
  local label="$1" log="$2" other
  other="$(grep -Fxv "auth status" "$log" 2>/dev/null || true)"
  [ -z "$other" ] || fail "$label made a gh call beyond the dispatcher's own 'auth status' prereq probe: $other"
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

REAL_HOME_BEFORE="$HOME"

# No-residue baseline (test 5, below): snapshot the exact real-HOME paths a
# REAL (unsandboxed) bootstrap.sh/init.sh/eject.sh run would write to,
# BEFORE the sandboxed cycle — some of these can legitimately pre-exist on
# an operator's real machine for unrelated reasons (e.g. this repo's own
# report-auto-offer dismiss state under .local/state/foundation), so the
# assertion is "unchanged", never "absent" — same before/after form as
# workflows/scripts/tests/lib/tests/test_sandbox.sh's own test 5.
snapshot_path() {
  # snapshot_path PATH — "absent" if it doesn't exist, else "present:<n>"
  # where <n> is a portable file-count fingerprint (no stat flags, works on
  # both BSD/macOS and GNU find).
  #
  # The basic-memory knowledge store (F#946) lives under
  # ~/.local/state/foundation/{basic-memory-home,bm-*} and is LIVE, concurrently
  # written runtime state — churned on-demand by ks_search / the
  # CLAUDE.kernel.md § Phase-1 parity `bm` leg from any other session or hook,
  # with hundreds of files created inside a single test window. It is NOT the
  # bootstrap residue this guard looks for, so counting it makes test 5 flake on
  # unrelated concurrent bm activity (temperloop#382, completing #377's fix in
  # the sibling test_sandbox.sh — this file's snapshot_path was missed there).
  # Prune the bm subtrees:
  #   - by directory NAME — the bm dirs only ever appear under
  #     .local/state/foundation, so a global name-prune cannot hide bootstrap
  #     residue leaked into any other REAL_CANDIDATE path;
  #   - via -prune, so the 400k+-file store is never descended (fast, and the
  #     count stays a leak-detector, not a store-size measurement).
  local p="$1"
  if [ -e "$p" ]; then
    printf 'present:%s' "$(find "$p" \( -name basic-memory-home -o -name 'bm-*' \) -prune -o -print 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf 'absent'
  fi
}
REAL_CANDIDATES=(
  "$REAL_HOME_BEFORE/.local/share/temperloop"
  "$REAL_HOME_BEFORE/.local/bin/temperloop"
  "$REAL_HOME_BEFORE/.local/bin/foundation"
  "$REAL_HOME_BEFORE/.config/foundation"
  "$REAL_HOME_BEFORE/.cache/temperloop"
  "$REAL_HOME_BEFORE/.local/state/foundation"
)
snaps_before=()
for p in "${REAL_CANDIDATES[@]}"; do
  snaps_before+=("$(snapshot_path "$p")")
done

sandbox_up test-dry-run-legs
sandbox_stub_gh
sandbox_stub_claude

# ---------------------------------------------------------------------------
# 1. Bootstrap this repo's own committed HEAD over file:// -> a real,
#    working temperloop binary inside the sandbox.
# ---------------------------------------------------------------------------
sandbox_bootstrap_checkout "$REPO_ROOT" || fail "sandbox_bootstrap_checkout failed"
[ -x "${SANDBOX_TEMPERLOOP:-}" ] || fail "SANDBOX_TEMPERLOOP not set/executable after bootstrap"
pass "0: bootstrapped a working temperloop binary over file:// (no network)"

# ---------------------------------------------------------------------------
# 2. Throwaway TARGET repo — a BARE local upstream (push-able) + a clone,
#    same fixture shape as bin/subcommands/tests/test_init.sh's own
#    new_fixture_repo. A local (non-github.com) origin, deliberately — this
#    is what keeps baseline-snapshot.sh's own gh-repo inference a no-op
#    (see that script's "no origin remote"-shaped degrade path), matching
#    the zero-gh-calls assertions below.
# ---------------------------------------------------------------------------
TARGET_UPSTREAM="$SANDBOX_ROOT/target-upstream.git"
TARGET="$SANDBOX_ROOT/target-repo"
git init -q --bare --initial-branch=main "$TARGET_UPSTREAM"
git clone -q "$TARGET_UPSTREAM" "$TARGET" 2>/dev/null
git -C "$TARGET" commit -q --allow-empty -m init
git -C "$TARGET" push -q origin main 2>/dev/null
git -C "$TARGET" fetch -q origin

# ---------------------------------------------------------------------------
# 3. init --dry-run leg: --no-network --dry-run (test_init.sh's own test-1
#    flag combination) -> exit 0, ZERO gh calls, GENUINELY ZERO-WRITE
#    (temperloop#413): no .foundation/config, no .foundation/baseline.jsonl,
#    no commit, HEAD/branch/status left exactly as they were. Mirrors what
#    bin/subcommands/tests/test_init.sh's own (rewritten) test 1 already
#    asserts at the bare-subcommand level; this leg re-proves it through the
#    bootstrapped CLI dispatcher.
# ---------------------------------------------------------------------------
target_head_before="$(git -C "$TARGET" rev-parse HEAD)"
target_branch_before="$(git -C "$TARGET" branch --show-current)"
target_status_before="$(git -C "$TARGET" status --porcelain)"

: > "$SANDBOX_GH_CALL_LOG"
init_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" init \
  --dir "$TARGET" --gh-repo acme/widget --no-network --dry-run \
  --yes-required-check --yes-labels 2>&1)"
init_rc=$?
[ "$init_rc" -eq 0 ] || fail "init --dry-run exited $init_rc (output: $init_out)"
assert_no_mutating_gh_calls "init --dry-run" "$SANDBOX_GH_CALL_LOG"
[ -e "$TARGET/.foundation/config" ] \
  && fail "init --dry-run wrote .foundation/config to disk (must be zero-write)"
[ -e "$TARGET/.foundation/baseline.jsonl" ] \
  && fail "init --dry-run wrote .foundation/baseline.jsonl (baseline snapshot must be gated by --dry-run)"
git -C "$TARGET" show HEAD:.foundation/config >/dev/null 2>&1 \
  && fail "init --dry-run committed .foundation/config locally (must be zero-write)"
[ "$(git -C "$TARGET" rev-parse HEAD)" = "$target_head_before" ] \
  || fail "init --dry-run moved HEAD"
[ "$(git -C "$TARGET" branch --show-current)" = "$target_branch_before" ] \
  || fail "init --dry-run switched branches"
[ "$(git -C "$TARGET" status --porcelain)" = "$target_status_before" ] \
  || fail "init --dry-run left the target checkout dirty"
pass "1: 'temperloop init --dry-run' (through the bootstrapped CLI) exits 0, makes zero gh calls beyond the dispatcher's own read-only prereq probe, is genuinely zero-write (no .foundation/config, no baseline.jsonl, no commit, HEAD/branch/status unchanged)"

# ---------------------------------------------------------------------------
# 4. eject --dry-run leg: exit 0, ZERO gh calls, .foundation/config left
#    untouched (mirrors test_eject.sh's own test 2). Since init --dry-run is
#    now genuinely zero-write (test 1 above) it no longer leaves a
#    .foundation/config behind for this leg to exercise eject against, so
#    seed one directly — same seed_config fixture shape as
#    bin/subcommands/tests/test_eject.sh.
# ---------------------------------------------------------------------------
mkdir -p "$TARGET/.foundation"
jq -n '{schema:1, generated_at:"2026-01-01T00:00:00Z",
        probe:{schema:1}, tracker:{mode:"issues", board:1},
        installs:[{type:"label", repo:"acme/widget", name:"fnd:status:backlog"}]}' \
  > "$TARGET/.foundation/config"
git -C "$TARGET" add -A -- .foundation/config
git -C "$TARGET" commit -q -m "seed .foundation/config"
config_before="$(cat "$TARGET/.foundation/config")"
: > "$SANDBOX_GH_CALL_LOG"
eject_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" eject --dir "$TARGET" --dry-run 2>&1)"
eject_rc=$?
[ "$eject_rc" -eq 0 ] || fail "eject --dry-run exited $eject_rc (output: $eject_out)"
assert_no_mutating_gh_calls "eject --dry-run" "$SANDBOX_GH_CALL_LOG"
[ -f "$TARGET/.foundation/config" ] || fail "eject --dry-run removed .foundation/config (should be untouched)"
[ "$(cat "$TARGET/.foundation/config")" = "$config_before" ] || fail "eject --dry-run modified .foundation/config (should be untouched)"
pass "2: 'temperloop eject --dry-run' (through the bootstrapped CLI) exits 0, makes zero gh calls beyond the dispatcher's own read-only prereq probe, leaves .foundation/config untouched"

# ---------------------------------------------------------------------------
# 5. No-residue: compare the real-HOME snapshot taken before sandbox_up
#    against the same paths now, after the full bootstrap+init+eject
#    cycle — must be byte-for-byte unchanged (same existence + same
#    portable file-count fingerprint).
# ---------------------------------------------------------------------------
i=0
for p in "${REAL_CANDIDATES[@]}"; do
  after="$(snapshot_path "$p")"
  [ "$after" = "${snaps_before[$i]}" ] \
    || fail "5: real-HOME path changed during the sandboxed run: $p (before: ${snaps_before[$i]}, after: $after)"
  i=$((i + 1))
done

sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down
[ ! -e "$sandbox_root_snapshot" ] || fail "5: sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"
[ "$HOME" = "$REAL_HOME_BEFORE" ] || fail "5: caller's own \$HOME changed after the sandboxed cycle (got: $HOME)"

pass "3: no residue outside the throwaway root — none of the real-HOME install targets exist, sandbox_down removes the root entirely"

echo
echo "ALL PASS: test_sandbox_dry_run_legs.sh"
