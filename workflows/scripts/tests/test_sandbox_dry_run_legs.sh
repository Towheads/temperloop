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
#      workflows/scripts/tests/lib/tests/test_sandbox.sh's own test 5 uses —
#      now LITERALLY the same code, sandbox.sh's sandbox_real_candidates /
#      sandbox_snapshot_path / sandbox_diff_real_candidates
#      (temperloop#1154), rather than a second verbatim copy of it. It runs
#      with a CONTINUOUS third-party writer active against the real cache
#      store root, so the leg cannot pass merely because nothing was writing.
#      The controlled proof for a STILL-SAMPLED root — `.local/state/
#      foundation`, temperloop#1241 — lives in test_sandbox.sh 6b, against a
#      synthetic root that suite owns; see sandbox_subtree_interferer_start.
#
# No network. The ONLY real-machine writes are test 5's interferer markers
# under the real cache store root — pid-namespaced, and removed (along with
# the root itself if this run created it) by sandbox_cache_interferer_stop,
# which is wired onto an EXIT trap. No real HOME/XDG mutations otherwise; in
# particular this suite never writes the real `.local/state/foundation`,
# which it still SAMPLES.
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
# through the real `temperloop` CLI. Per-subcommand prereq scoping
# (temperloop#412) means the dispatcher's prereq gate
# (bin/lib/common.sh: foundation_check_prereqs) only probes `gh auth
# status` for a subcommand that declares `gh` via its own `# prereqs: ...`
# header — neither init.sh nor eject.sh does, so in practice this asserts
# ZERO gh calls today. The helper still tolerates one bare "auth status"
# line rather than requiring the log be empty, so it stays valid without
# editing if init/eject ever legitimately opt into that dispatcher-level
# probe.
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
# snapshot_path and the candidate list are sandbox.sh's
# (sandbox_snapshot_path / sandbox_real_candidates, temperloop#1154). They
# used to be a verbatim second copy of test_sandbox.sh's, which is why #377's
# bm-prune fix had to be re-made here as #382 — the comments had already
# drifted apart by then. Hoisted, so the next contract change is made once.
sandbox_real_candidates "$REAL_HOME_BEFORE"

# A CONTINUOUS third-party writer against the REAL cache store root, live for
# the whole of assertion 5 — the concurrent board-adapter traffic that made
# count-sampling that root un-attributable in the first place. Without it
# this leg passes vacuously.
#
# The still-sampled `.local/state/foundation` root deliberately gets NO
# interferer, and is deliberately not written to by this suite at all: its
# controlled concurrency proof lives in test_sandbox.sh 6b, against a
# synthetic root that suite owns. See sandbox_subtree_interferer_start's
# comment — a writer aimed at the REAL root makes these two suites fail each
# other the moment quality-gates.sh runs them in parallel (temperloop#1241).
trap 'sandbox_cache_interferer_stop' EXIT
sandbox_cache_interferer_start || fail "5: could not start the cache-root interferer"

sandbox_snapshot_real_candidates

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
drift="$(sandbox_diff_real_candidates)" || fail "5: $drift"

# Non-vacuity: prove the interferer really was writing the real cache store
# root, concurrently, for the duration of the assertion above. Asserted
# BEFORE stopping it — the stop removes its markers.
interferer_writes="$(sandbox_cache_interferer_count)"
[ "$interferer_writes" -ge 2 ] \
  || fail "5: the third-party cache-root interferer laid down only $interferer_writes marker(s) — assertion 5 did not actually run against a concurrent writer"
sandbox_cache_interferer_stop
trap - EXIT

sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down
[ ! -e "$sandbox_root_snapshot" ] || fail "5: sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"
[ "$HOME" = "$REAL_HOME_BEFORE" ] || fail "5: caller's own \$HOME changed after the sandboxed cycle (got: $HOME)"

pass "3: no residue outside the throwaway root — every real-HOME install target is unchanged even with a concurrent third-party writer ($interferer_writes writes) active against the real cache store root, and sandbox_down removes the root entirely"

echo
echo "ALL PASS: test_sandbox_dry_run_legs.sh"
