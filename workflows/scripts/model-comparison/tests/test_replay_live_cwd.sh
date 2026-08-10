#!/usr/bin/env bash
#
# test_replay_live_cwd.sh — the LIVE arm's working-directory handoff
# (temperloop#1376, epic #1225 "model comparison harness").
#
# ── WHY THIS SUITE EXISTS SEPARATELY FROM test_replay_score.sh ─────────────
# Every other `replay.sh execute` fixture drives the STUB runner arm, which
# receives the replay worktree as an explicit second argument
# (`$runner "$prompt_file" "$wt"`). That arm therefore CANNOT observe the
# defect this file pins: the LIVE arm spawns `candidate-session.sh spawn`,
# hands it no worktree argument at all, and — before #1376 — never changed
# directory either. A real headless session works in the directory it was
# spawned in, so the live candidate ran against the CALLER's tree while the
# prompt merely *told* it to work in $wt. Prompt prose is a request, not a
# mechanism. A suite that only exercises the stub arm proves nothing about
# this seam, which is exactly why the defect survived a full unit suite and
# was only found by a live validation run.
#
# ── WHAT IS ASSERTED, AND WHY IT IS GUARD-INDEPENDENT ─────────────────────
# The suite runs `replay.sh execute --live` from a cwd that is a DIFFERENT,
# REAL GIT REPOSITORY (`$OPERATOR`) standing in for the operator's own
# checkout. The candidate double records, from inside its own process:
#
#   1. `pwd -P`                        → must equal the replay worktree
#   2. `git rev-parse --show-toplevel` → must equal the replay worktree, and
#                                        must NOT be $OPERATOR
#
# Assertion 2 is the latent half of the issue (CONSEQUENCE 2) stated as a
# measurement: it says a candidate's cwd-relative git command resolves
# INSIDE the replay worktree. Nothing here arms, mocks or depends on the
# build-worktree-guard PreToolUse hook — on a host where that guard is
# unarmed, the pre-fix code let a candidate commit into $OPERATOR, and this
# assertion is what makes that impossible rather than merely blocked.
#
# ── HERMETIC BY CONSTRUCTION ──────────────────────────────────────────────
# `--live` here does NOT mean a network call. The live arm's one external
# dependency is the `claude` binary, reached through candidate-session.sh's
# documented `CLAUDE_BIN` test-double seam; this suite points it at a local
# recording script. As a second, independent mechanism (the same convention
# test_replay_score.sh uses) a canary `claude` is prepended to PATH for the
# whole suite and section D asserts it was never invoked — so "no real model
# call" is a measured property of the run, not a claim about the tests that
# happened to be checked. No network, no `gh`, no writes outside $TMPDIR.
#
# Sections:
#   A  the live arm spawns with the replay worktree as its actual cwd
#   B  a candidate's cwd-relative git resolves inside the worktree, not the
#      operator's checkout (guard-independent)
#   C  the stub/offline arm is unchanged — still handed $wt as argument 2
#   D  the suite-wide no-real-claude canary verdict
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_live_cwd.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
REPLAY="$MC_DIR/replay.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-live-cwd-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE CANARY — a `claude` on PATH that nothing in this suite may reach.
# ═══════════════════════════════════════════════════════════════════════════
CANARY="$WORK/CANARY"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

git_init() {  # git_init <dir>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name  T
  git -C "$d" config commit.gpgsign false
}

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE REPO — the tree replay worktrees are cut from.
# ═══════════════════════════════════════════════════════════════════════════
REPO="$WORK/repo"
git_init "$REPO"
mkdir -p "$REPO/scripts" "$REPO/src"
printf 'at base\n' >"$REPO/src/thing.txt"
cat >"$REPO/scripts/quality-gates.sh" <<'GATE'
#!/usr/bin/env bash
echo "fixture gate: OK"
exit 0
GATE
chmod +x "$REPO/scripts/quality-gates.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -qb truth
printf 'at truth\n' >"$REPO/src/thing.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm truth
TRUTH="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q master 2>/dev/null || git -C "$REPO" checkout -q main

# ── the OPERATOR's own checkout — a REAL, DIFFERENT git repo, used as the
#    caller's cwd so a spawn that never changed directory lands here. This is
#    the tree the pre-fix live arm would have let a candidate commit into on a
#    host with no build-worktree guard armed. ────────────────────────────────
OPERATOR="$WORK/operator-checkout"
git_init "$OPERATOR"
printf 'operator work\n' >"$OPERATOR/README.md"
git -C "$OPERATOR" add -A
git -C "$OPERATOR" commit -qm operator

mk_wt() {  # prints a FRESH replay worktree rewound to $BASE
  local p slug
  p="$(mktemp -d "$WORK/wt-XXXXXX")" || return 1
  rm -rf "$p"
  slug="cand-$(basename "$p")"
  git -C "$REPO" worktree add -q -b "$slug" "$p" "$BASE" >/dev/null 2>&1 || return 1
  ( cd -P "$p" && pwd )
}

RECORD="$WORK/record.json"
jq -cn --arg base "$BASE" --arg head "$TRUTH" \
  '{schema_version:"replay-record-v1", pr:999, issue:"#1376",
    merge_commit:null, base:$base, head:$head,
    title:"live arm cwd handoff", scope:"replay.sh execute",
    acceptance:["The spawn runs inside the replay worktree."],
    notes:"", status:"eligible", reject_reason:"", flags:[],
    buckets:{N:["src/thing.txt"], T:[], X:[], R:[]},
    template_sha:"deadbeef", file_count:1,
    worktree:{path:null,branch:null,prepared_at:null},
    candidate:{provider:null,model:null,diff_ref:null},
    score:{verdict:null,acceptance_results:null,gate_result:null}}' >"$RECORD"

ENVELOPE="$WORK/envelope.json"
jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:1234,
         modelUsage:{"claude-recorded-candidate":
           {inputTokens:10, outputTokens:5,
            cacheReadInputTokens:0, cacheCreationInputTokens:0}}}' >"$ENVELOPE"

# ── the CLAUDE_BIN test double: it records the process's OWN view of where
#    it is running, from inside the spawned child. Every observation path is
#    baked in as a literal, because candidate-session.sh spawns the child
#    under `env -i` + a named allowlist — no fixture env var survives that
#    boundary, so a double that read one would silently record nothing. ─────
OBSERVED_CWD="$WORK/observed-cwd.txt"
OBSERVED_TOPLEVEL="$WORK/observed-toplevel.txt"
OBSERVED_ARGS="$WORK/observed-args.txt"
STUB_CLAUDE="$WORK/claude-double.sh"
cat >"$STUB_CLAUDE" <<STUBEOF
#!/usr/bin/env bash
set -u
pwd -P >"$OBSERVED_CWD"
git rev-parse --show-toplevel >"$OBSERVED_TOPLEVEL" 2>/dev/null || printf 'NO-GIT\n' >"$OBSERVED_TOPLEVEL"
printf '%s\n' "\$*" >"$OBSERVED_ARGS"
cat >/dev/null   # drain the prompt on stdin, exactly as \`claude -p\` would
cat "$ENVELOPE"
STUBEOF
chmod +x "$STUB_CLAUDE"

# ── the OFFLINE stub runner (section C) — records the arguments the stub arm
#    is handed, so "the stub arm is unchanged" is measured, not assumed. ────
STUB_ARG2="$WORK/stub-arg2.txt"
STUB_RUNNER="$WORK/stub-runner.sh"
cat >"$STUB_RUNNER" <<STUBEOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$2" >"$STUB_ARG2"
printf 'candidate edit\n' >"\$2/src/thing.txt"
cat "$ENVELOPE"
STUBEOF
chmod +x "$STUB_RUNNER"

LAKE="$WORK/lake"; mkdir -p "$LAKE"

run_exec_from_operator() {  # run from the OPERATOR checkout, never from $wt
  ( cd "$OPERATOR" && env \
      CLAUDE_BIN="$STUB_CLAUDE" \
      MODEL_USAGE_RAW_DIR="$LAKE" \
      REPLAY_CANDIDATE_TIMEOUT_SECS=120 \
      bash "$REPLAY" execute "$@" )
}

# ═══════════════════════════════════════════════════════════════════════════
# A. The live arm's spawn cwd IS the replay worktree.
# ═══════════════════════════════════════════════════════════════════════════
WT_A="$(mk_wt)" || fail "could not prepare a replay worktree"
rm -f "$OBSERVED_CWD" "$OBSERVED_TOPLEVEL" "$OBSERVED_ARGS"

out_a="$(run_exec_from_operator --record "$RECORD" --repo-root "$REPO" \
           --worktree "$WT_A" --live --out "$WORK/rec-a.json" 2>"$WORK/err-a.txt")"
rc_a=$?

count
[ -f "$OBSERVED_CWD" ] || fail "A1 the live arm never reached the CLAUDE_BIN double at all (rc=$rc_a) — stderr: $(head -c 400 "$WORK/err-a.txt")"
observed_cwd="$(cat "$OBSERVED_CWD")"
if [ "$observed_cwd" = "$WT_A" ]; then
  ok "A1 live arm spawned with the replay worktree as its cwd ($observed_cwd)"
else
  fail "A1 live arm spawned in the WRONG directory
       want cwd: $WT_A
       got  cwd: $observed_cwd
       (caller cwd was $OPERATOR — a spawn that inherits it measures the wrong tree)"
fi

count
if [ "$observed_cwd" != "$OPERATOR" ]; then
  ok "A2 live arm did NOT inherit the caller's cwd"
else
  fail "A2 live arm inherited the caller's cwd ($OPERATOR) — the #1376 defect"
fi

count
if [ "$rc_a" -eq 0 ] && printf '%s' "$out_a" | jq -e 'type=="object"' >/dev/null 2>&1; then
  ok "A3 the live run still produced a record (rc=0, JSON object on stdout)"
else
  fail "A3 the live run did not produce a record (rc=$rc_a): $(head -c 400 "$WORK/err-a.txt")"
fi

count
if printf '%s' "$out_a" | jq -e '.candidate.outcome != "integration-error"' >/dev/null 2>&1; then
  ok "A4 the live run is a scored record, not an integration error"
else
  fail "A4 the live run reported an integration error: $(printf '%s' "$out_a" | jq -c '.candidate.integration_error // "?"')"
fi

# The cwd handoff must not have cost the containment overlay: the child is
# still invoked through candidate-session.sh, so it still carries --settings.
count
observed_args="$(cat "$OBSERVED_ARGS" 2>/dev/null || printf '')"
case "$observed_args" in
  *--settings*) ok "A5 the spawn still routes through candidate-session.sh's containment overlay (--settings present)" ;;
  *) fail "A5 the child was invoked WITHOUT --settings — containment lost: '$observed_args'" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# B. A candidate's cwd-relative git resolves INSIDE the replay worktree.
#    This is the guard-independent half: no PreToolUse hook is armed here.
# ═══════════════════════════════════════════════════════════════════════════
count
observed_top="$(cat "$OBSERVED_TOPLEVEL" 2>/dev/null || printf 'MISSING')"
observed_top_resolved="$observed_top"
[ -d "$observed_top" ] && observed_top_resolved="$( cd -P "$observed_top" && pwd )"
if [ "$observed_top_resolved" = "$WT_A" ]; then
  ok "B1 the candidate's own \`git rev-parse --show-toplevel\` resolves to the replay worktree"
else
  fail "B1 the candidate's cwd-relative git resolved OUTSIDE the replay worktree
       want toplevel: $WT_A
       got  toplevel: $observed_top_resolved"
fi

count
operator_top="$( cd -P "$OPERATOR" && pwd )"
if [ "$observed_top_resolved" != "$operator_top" ]; then
  ok "B2 the candidate could not have committed into the operator's checkout"
else
  fail "B2 the candidate's git resolved to the OPERATOR's checkout ($operator_top) — on a host with no build-worktree guard armed it would commit there"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C. The stub/offline arm is unchanged — still handed $wt as argument 2.
# ═══════════════════════════════════════════════════════════════════════════
WT_C="$(mk_wt)" || fail "could not prepare a replay worktree"
rm -f "$STUB_ARG2"
out_c="$(run_exec_from_operator --record "$RECORD" --repo-root "$REPO" \
           --worktree "$WT_C" --candidate-runner "bash $STUB_RUNNER" \
           --out "$WORK/rec-c.json" 2>"$WORK/err-c.txt")"
rc_c=$?

count
[ -f "$STUB_ARG2" ] || fail "C1 the stub arm never invoked the recorded runner (rc=$rc_c): $(head -c 400 "$WORK/err-c.txt")"
stub_arg2="$(cat "$STUB_ARG2")"
stub_arg2_resolved="$stub_arg2"
[ -d "$stub_arg2" ] && stub_arg2_resolved="$( cd -P "$stub_arg2" && pwd )"
if [ "$stub_arg2_resolved" = "$WT_C" ]; then
  ok "C1 the stub arm still receives the replay worktree as its second argument"
else
  fail "C1 the stub arm's second argument changed
       want: $WT_C
       got:  $stub_arg2_resolved"
fi

count
if [ "$rc_c" -eq 0 ] && printf '%s' "$out_c" | jq -e 'type=="object"' >/dev/null 2>&1; then
  ok "C2 the stub arm still produces a record (rc=0)"
else
  fail "C2 the stub arm regressed (rc=$rc_c): $(head -c 400 "$WORK/err-c.txt")"
fi

count
if printf '%s' "$out_c" | jq -e '.candidate.outcome != "integration-error"' >/dev/null 2>&1; then
  ok "C3 the stub arm's record is scored, not an integration error"
else
  fail "C3 the stub arm reported an integration error: $(printf '%s' "$out_c" | jq -c '.candidate.integration_error // "?"')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D. The canary — nothing in this suite invoked a real `claude`.
# ═══════════════════════════════════════════════════════════════════════════
count
if [ -f "$CANARY" ]; then
  fail "D1 a bare \`claude\` on PATH WAS invoked — this suite is not hermetic: $(head -c 400 "$CANARY")"
fi
ok "D1 no bare \`claude\` on PATH was ever invoked (canary never fired)"

echo
echo "test_replay_live_cwd.sh: $pass/$total passed"
[ "$pass" -eq "$total" ] || exit 1
exit 0
