#!/usr/bin/env bash
#
# test_validate_mandatory_step_signal.sh — fixture suite for
# workflows/scripts/validate-mandatory-step-signal.sh (temperloop#1448,
# epic #1616 "mandatory but never runs").
#
# THE DISCRIMINATION CONTROL IS THE POINT OF THIS SUITE, not an add-on. The
# acceptance criterion the gate was built against is: "a change that declares
# a step mandatory WITHOUT a signal fails the validator; one that ships both
# passes." Cases 1 and 2 are exactly that pair, over the SAME scratch spec —
# the only difference between them is whether the registry row exists. Every
# other case pins one way the pair can go half-present after the fact.
#
# Hermetic: every fixture is a fresh subdirectory of one throwaway mktemp dir
# OUTSIDE this repo, driven entirely through the gate's documented env seams
# (MANDATORY_STEP_*). No network, no writes inside the repo. The two ratchet
# cases build their own throwaway git repo.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays), matching every
# sibling workflows/scripts/tests/ suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$REPO_ROOT/workflows/scripts/validate-mandatory-step-signal.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-mandatory-step-signal-XXXXXX")" || exit 1
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }

TAB="$(printf '\t')"

# ---------------------------------------------------------------------------
# _scaffold <name> — build a scratch "repo" and echo its root. Every case
# starts from the SAME well-formed world (one spec declaring one step
# mandatory, one signal file carrying the anchor, one gate file) and then
# breaks exactly one thing, so a failure is attributable to that one thing.
# ---------------------------------------------------------------------------
_scaffold() {
  local root="$WORK/$1"
  mkdir -p "$root/claude/commands" "$root/scripts" "$root/sig"

  cat >"$root/claude/commands/demo.md" <<'SPEC'
# /demo

## Step 3 — the reviewed pass

**Mandatory for every run:** the reviewed pass is required, never worker
discretion, and it emits its own tally.

Some ordinary prose that mentions nothing special.

```
a fenced example that says mandatory and must not be discovered
```
SPEC

  cat >"$root/sig/runner.mjs" <<'SIG'
// the executing code's own per-run record
return { ran, skipped, mandatory_ok: !skipped.length };
SIG

  cat >"$root/scripts/quality-gates.sh" <<'QG'
#!/usr/bin/env bash
GATES=(
  "bash sig/demo-guard.sh"
  # "bash sig/disabled-guard.sh"
)
QG

  cat >"$root/sig/demo-guard.sh" <<'GUARD'
#!/usr/bin/env bash
# the reviewed pass is spawned from driveItem, never the worker
GUARD
  cat >"$root/sig/disabled-guard.sh" <<'GUARD'
#!/usr/bin/env bash
# the reviewed pass is spawned from driveItem, never the worker
GUARD

  printf '%s\n' "$root"
}

# _registry <root> <kind> <signal> <anchor> <gate> — write a one-row registry.
_registry() {
  local root="$1" kind="$2" signal="$3" anchor="$4" gate="$5"
  printf '# fixture registry\n' >"$root/registry.tsv"
  printf 'claude/commands/demo.md%sStep 3%s**Mandatory for every run:**%s%s%s%s%s%s%s%s%sthe pass emits a per-run tally\n' \
    "$TAB" "$TAB" "$TAB" "$kind" "$TAB" "$signal" "$TAB" "$anchor" "$TAB" "$gate" "$TAB" \
    >>"$root/registry.tsv"
}

# _run <root> [extra env assignments...] — invoke the gate against <root>,
# capture combined output in RUN_OUT and the exit code in RUN_RC.
RUN_OUT=""
RUN_RC=0
_run() {
  local root="$1"
  shift
  RUN_OUT="$(
    env \
      MANDATORY_STEP_REPO_ROOT="$root" \
      MANDATORY_STEP_GIT_REPO_ROOT="${MSS_GIT_ROOT:-$root}" \
      MANDATORY_STEP_REGISTRY_FILE="$root/registry.tsv" \
      MANDATORY_STEP_DISCOVERY_FILE="$root/ledger.tsv" \
      MANDATORY_STEP_SPEC_DIR="$root/claude/commands" \
      MANDATORY_STEP_QUALITY_GATES_FILE="$root/scripts/quality-gates.sh" \
      "$@" \
      bash "$GATE" 2>&1
  )"
  RUN_RC=$?
}

# _expect <label> <want-rc> <want-substring>
_expect() {
  local label="$1" want_rc="$2" want_sub="$3"
  if [ "$RUN_RC" -ne "$want_rc" ]; then
    bad "$label" "expected exit $want_rc, got $RUN_RC — output: $RUN_OUT"
    return
  fi
  if [ -n "$want_sub" ] && ! printf '%s' "$RUN_OUT" | grep -F -- "$want_sub" >/dev/null; then
    bad "$label" "expected output to contain '$want_sub' — output: $RUN_OUT"
    return
  fi
  ok "$label"
}

echo "== the discrimination pair (the acceptance criterion) =="

# ── 1. GREEN: declaration + signal shipped together ────────────────────────
R="$(_scaffold green)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
: >"$R/ledger.tsv"
_run "$R"
_expect "a declaration registered WITH its execution signal passes" 0 "validate-mandatory-step-signal: OK"

# ── 2. RED: the SAME declaration, signal never shipped ─────────────────────
#    The one and only difference from case 1 is the missing registry row.
R="$(_scaffold nosignal)"
printf '# fixture registry\n' >"$R/registry.tsv"
printf 'claude/commands/other.md%sfiller%sunrelated mandatory filler row%stally%ssig/runner.mjs%smandatory_ok%s-%skeeps the registry non-empty\n' \
  "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >>"$R/registry.tsv"
mkdir -p "$R/claude/commands"
printf 'an unrelated mandatory filler row\n' >"$R/claude/commands/other.md"
: >"$R/ledger.tsv"
_run "$R"
_expect "declaring a step mandatory with NO signal fails, naming the line" 1 "UNDISPOSED-DECLARATION  claude/commands/demo.md:5"

echo "== half-present pairs (either half can rot after the fact) =="

# ── 3. the SIGNAL file disappears ──────────────────────────────────────────
R="$(_scaffold nosigfile)"
_registry "$R" tally sig/gone.mjs 'mandatory_ok' -
: >"$R/ledger.tsv"
_run "$R"
_expect "a registered pair whose SIGNAL file is gone is HALF-PRESENT" 1 "HALF-PRESENT"

# ── 4. the signal file survives but its ANCHOR was renamed ─────────────────
R="$(_scaffold noanchor)"
_registry "$R" tally sig/runner.mjs 'review_tally_v2' -
: >"$R/ledger.tsv"
_run "$R"
_expect "a renamed signal field turns the pair red" 1 "SIGNAL-ANCHOR-MISSING"

# ── 5. the DECLARATION half is reworded away ───────────────────────────────
R="$(_scaffold nodecl)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
: >"$R/ledger.tsv"
# Reword the declaration out of the spec entirely, leaving no marker line.
printf '# /demo\n\nThe reviewed pass happens when it happens.\n' >"$R/claude/commands/demo.md"
_run "$R"
_expect "a reworded-away declaration is HALF-PRESENT, not a silent pass" 1 "HALF-PRESENT"

echo "== a guard nobody runs is not a signal =="

# ── 6. KIND=guard wired into an ACTIVE gate line ───────────────────────────
R="$(_scaffold gated)"
_registry "$R" guard sig/demo-guard.sh 'spawned from driveItem' 'bash sig/demo-guard.sh'
: >"$R/ledger.tsv"
_run "$R"
_expect "a guard on an ACTIVE quality-gates.sh line is an accepted signal" 0 "validate-mandatory-step-signal: OK"

# ── 7. the same guard, but its gate line is COMMENTED OUT ──────────────────
R="$(_scaffold ungated)"
_registry "$R" guard sig/disabled-guard.sh 'spawned from driveItem' 'bash sig/disabled-guard.sh'
: >"$R/ledger.tsv"
_run "$R"
_expect "a guard whose gate line is commented out is NOT a signal" 1 "GUARD-NOT-GATED"

# ── 8. KIND=guard with no GATE token at all ────────────────────────────────
R="$(_scaffold nogate)"
_registry "$R" guard sig/demo-guard.sh 'spawned from driveItem' '-'
: >"$R/ledger.tsv"
_run "$R"
_expect "a guard row must name the gate that runs it" 1 "GUARD-UNGATED"

echo "== registry integrity =="

# ── 9. an anchor that pins a line carrying no marker ───────────────────────
R="$(_scaffold notmandatory)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
# Repoint the DECLARATION at ordinary prose, so the row would otherwise
# "cover" a line the discovery pass never flagged.
printf '# fixture registry\n' >"$R/registry.tsv"
printf 'claude/commands/demo.md%sStep 3%sSome ordinary prose%stally%ssig/runner.mjs%smandatory_ok%s-%sbogus\n' \
  "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >>"$R/registry.tsv"
: >"$R/ledger.tsv"
_run "$R"
_expect "a row anchored on a non-declaring line is rejected" 1 "DECLARATION-NOT-MANDATORY"

# ── 10. an unknown KIND ────────────────────────────────────────────────────
R="$(_scaffold badkind)"
_registry "$R" vibes sig/runner.mjs 'mandatory_ok' -
: >"$R/ledger.tsv"
_run "$R"
_expect "an unrecognised signal KIND is rejected" 1 "SIGNAL-KIND-UNKNOWN"

# ── 11. an empty registry is a vacuous pass, so it fails ───────────────────
R="$(_scaffold emptyreg)"
printf '# nothing but a comment\n' >"$R/registry.tsv"
: >"$R/ledger.tsv"
_run "$R"
_expect "a comment-only registry fails rather than passing vacuously" 1 "EMPTY-REGISTRY"

echo "== the disposition ledger =="

# ── 12. `excluded` disposes a marker line ──────────────────────────────────
R="$(_scaffold excluded)"
printf '# fixture registry\n' >"$R/registry.tsv"
printf 'claude/commands/other.md%sfiller%sunrelated mandatory filler row%stally%ssig/runner.mjs%smandatory_ok%s-%skeeps the registry non-empty\n' \
  "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >>"$R/registry.tsv"
printf 'an unrelated mandatory filler row\n' >"$R/claude/commands/other.md"
printf 'claude/commands/demo.md%s**Mandatory for every run:**%sexcluded%snot a step-execution declaration in this fixture\n' \
  "$TAB" "$TAB" "$TAB" >"$R/ledger.tsv"
_run "$R"
_expect "an 'excluded' disposition satisfies the discovery pass" 0 "validate-mandatory-step-signal: OK"

# ── 13. a disposition with no reason ───────────────────────────────────────
R="$(_scaffold noreason)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
printf 'claude/commands/demo.md%sSome ordinary prose%sexcluded%s\n' "$TAB" "$TAB" "$TAB" >"$R/ledger.tsv"
_run "$R"
_expect "a disposition with no REASON is rejected" 1 "DISPOSITION-UNJUSTIFIED"

# ── 14. a ledger row whose anchor no longer exists ─────────────────────────
R="$(_scaffold stale)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
printf 'claude/commands/demo.md%sa sentence that was deleted long ago%sexcluded%sstale on purpose\n' \
  "$TAB" "$TAB" "$TAB" >"$R/ledger.tsv"
_run "$R"
_expect "a stale ledger anchor is reported, not silently ignored" 1 "LEDGER-STALE"

echo "== the fenced-example carve-out =="

# ── 15. a marker inside a ``` fence is not a declaration ───────────────────
#    Case 1 already proves this implicitly (its spec carries one), so assert
#    it explicitly: the discovered count must be 1, not 2.
R="$(_scaffold fence)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
: >"$R/ledger.tsv"
_run "$R"
_expect "a marker inside a fenced example is not counted as a declaration" 0 "over 1 discovered marker line(s)"

echo "== degenerate inputs fail closed (temperloop#1409 class) =="

# ── 16-18. absent / unreadable / empty registry ────────────────────────────
R="$(_scaffold degenerate)"
: >"$R/ledger.tsv"
_run "$R" MANDATORY_STEP_REGISTRY_FILE="$R/nope.tsv"
_expect "an ABSENT registry exits non-zero (CANNOT EVALUATE), not 0" 2 "CANNOT EVALUATE"

printf 'x\n' >"$R/unreadable.tsv"
chmod 000 "$R/unreadable.tsv"
_run "$R" MANDATORY_STEP_REGISTRY_FILE="$R/unreadable.tsv"
if [ "$RUN_RC" -eq 0 ]; then
  bad "an UNREADABLE registry exits non-zero" "got exit 0 — output: $RUN_OUT"
else
  ok "an UNREADABLE registry exits non-zero (CANNOT EVALUATE), not 0"
fi
chmod 644 "$R/unreadable.tsv"

: >"$R/empty.tsv"
_run "$R" MANDATORY_STEP_REGISTRY_FILE="$R/empty.tsv"
if [ "$RUN_RC" -eq 0 ]; then
  bad "an EMPTY registry exits non-zero" "got exit 0 — output: $RUN_OUT"
else
  ok "an EMPTY registry exits non-zero, never a silent OK"
fi

# ── 19. an unreadable ledger is never treated as "no dispositions" ─────────
R="$(_scaffold badledger)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
printf 'x\n' >"$R/ledger.tsv"
chmod 000 "$R/ledger.tsv"
_run "$R"
if [ "$RUN_RC" -eq 0 ]; then
  bad "an UNREADABLE ledger exits non-zero" "got exit 0 — output: $RUN_OUT"
else
  ok "an UNREADABLE ledger exits non-zero rather than reading as zero dispositions"
fi
chmod 644 "$R/ledger.tsv"

# ── 20. an empty spec corpus establishes nothing ───────────────────────────
R="$(_scaffold nospecs)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok' -
: >"$R/ledger.tsv"
rm -f "$R/claude/commands"/*.md
_run "$R"
_expect "an empty spec corpus is CANNOT EVALUATE, not a clean pass" 2 "CANNOT EVALUATE"

# ── 21. an EXPLICIT but unresolvable base ref ──────────────────────────────
R="$(_scaffold badref)"
_registry "$R" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
: >"$R/ledger.tsv"
_run "$R" MANDATORY_STEP_BASE_REF="refs/heads/definitely-not-a-ref"
_expect "an unresolvable EXPLICIT base ref is CANNOT EVALUATE" 2 "CANNOT EVALUATE"

echo "== the pending ratchet (the birth rule's teeth) =="

if ! command -v git >/dev/null 2>&1; then
  echo "  skip  pending-ratchet cases — git not available"
else
  R="$(_scaffold ratchet)"
  _registry "$R" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
  # Base state: a ledger with ONE pending row, committed.
  printf 'claude/commands/demo.md%sSome ordinary prose%spending%spre-existing debt\n' \
    "$TAB" "$TAB" "$TAB" >"$R/ledger.tsv"
  (
    cd "$R" || exit 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git add -A
    git commit -qm base
  ) >/dev/null 2>&1
  BASE_SHA="$(git -C "$R" rev-parse HEAD)"

  # 22. A NEW pending row cannot be parked.
  printf 'claude/commands/demo.md%s**Mandatory for every run:**%spending%snewly parked, which the ratchet forbids\n' \
    "$TAB" "$TAB" "$TAB" >>"$R/ledger.tsv"
  MSS_GIT_ROOT="$R" _run "$R" MANDATORY_STEP_BASE_REF="$BASE_SHA"
  _expect "a NEW mandatory declaration cannot be parked 'pending'" 1 "PENDING-GREW"

  # 23. Paying the debt down (removing a pending row) is a legal shrink.
  printf 'claude/commands/demo.md%s**Mandatory for every run:**%sexcluded%sdispositioned properly instead\n' \
    "$TAB" "$TAB" "$TAB" >"$R/ledger.tsv"
  MSS_GIT_ROOT="$R" _run "$R" MANDATORY_STEP_BASE_REF="$BASE_SHA"
  _expect "removing a pending row is a legal shrink" 0 "validate-mandatory-step-signal: OK"
fi

echo "---"
echo "passed: $pass | failed: $fail"
[ "$fail" -eq 0 ] || exit 1
