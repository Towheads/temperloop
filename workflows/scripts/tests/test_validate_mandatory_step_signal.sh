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
#
# EVERY config path is pinned inside the fixture, including the two overlay
# extensions (temperloop#1755). Leaving those at their defaults resolves them to
# the REAL $SCRIPT_DIR/config/*.overlay.tsv — absent in this repo, so the suite
# looked green, but present in a composed overlay, where the gate then read the
# adopter's live rows while running against a scratch fixture root and reported
# every one of their specs as missing. A test that reads config outside the
# fixture it was handed is not testing the fixture. The `"$@"` below still lets
# an individual case override either pin.
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
      MANDATORY_STEP_REGISTRY_OVERLAY_FILE="$WORK/no-such-registry.overlay.tsv" \
      MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$WORK/no-such-discovery.overlay.tsv" \
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

# ---------------------------------------------------------------------------
# 24-27. temperloop#1738/#1740 — THE OVERLAY EXTENSION SEAM.
#
# In a composed overlay both config files are compat symlinks into the vendored
# kernel subtree, so a consumer owning command specs of its own had nowhere to
# disposition their mandatory declarations. These pin the seam and its limit:
# it works (25), it is what makes the difference (24), it fails closed on an
# unreadable file (26), and it is NOT a debt parking lot (27).
# ---------------------------------------------------------------------------
OV="$(_scaffold overlay-seam)"
_registry "$OV" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
# A consumer-owned spec the kernel does not ship, carrying its own declaration.
cat >"$OV/claude/commands/consumer.md" <<'SPEC'
# /consumer

## Step 1 — the consumer's own pass

**Mandatory for every run:** this consumer-owned step is required.
SPEC
: >"$OV/ledger.tsv"

# 24 FIRST — the discrimination baseline. With no overlay extension the
# consumer's declaration is undispositioned and the gate is RED. If this ever
# goes green, 25 proves nothing.
_run "$OV"
_expect "without the overlay extension a consumer-owned declaration is UNDISPOSED" 1 "UNDISPOSED-DECLARATION"

# 25. The overlay extension dispositions it -> GREEN.
printf 'claude/commands/consumer.md%s**Mandatory for every run:**%sexcluded%sconsumer-owned; not a step-execution declaration\n' \
  "$TAB" "$TAB" "$TAB" >"$OV/ledger.overlay.tsv"
_run "$OV" MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$OV/ledger.overlay.tsv"
_expect "an overlay discovery extension dispositions a consumer-owned declaration" 0 "validate-mandatory-step-signal: OK"

# 26. An UNREADABLE overlay extension is CANNOT EVALUATE, never a silent pass.
if [ "$(id -u)" -ne 0 ]; then
  cp "$OV/ledger.overlay.tsv" "$OV/unreadable.overlay.tsv"
  chmod 000 "$OV/unreadable.overlay.tsv"
  _run "$OV" MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$OV/unreadable.overlay.tsv"
  chmod 644 "$OV/unreadable.overlay.tsv"
  # Exit 2 is this gate's CANNOT EVALUATE code (see the absent-registry case
  # above), distinct from 1 = a real finding. An unreadable disposition file is
  # not "no violations", it is "cannot tell", and the exit code must say so.
  _expect "an unreadable overlay extension fails closed (CANNOT EVALUATE)" 2 "overlay extension file exists but is not readable"
  rm -f "$OV/unreadable.overlay.tsv"
fi

# 27. THE LIMIT — the overlay pending set is shrink-only too. A seam that let a
#     consumer park declarations forever would be strictly worse than the hole
#     it closes: the same debt, now invisible to upstream.
if command -v git >/dev/null 2>&1; then
  OVR="$(_scaffold overlay-ratchet)"
  _registry "$OVR" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
  cat >"$OVR/claude/commands/consumer.md" <<'SPEC'
# /consumer

## Step 1 — the consumer's own pass

**Mandatory for every run:** this consumer-owned step is required.

Some ordinary prose that mentions nothing special.
SPEC
  : >"$OVR/ledger.tsv"
  printf 'claude/commands/consumer.md%s**Mandatory for every run:**%spending%spre-existing consumer debt\n' \
    "$TAB" "$TAB" "$TAB" >"$OVR/ledger.overlay.tsv"
  (
    cd "$OVR" || exit 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git add -A
    git commit -qm base
  ) >/dev/null 2>&1
  OVR_SHA="$(git -C "$OVR" rev-parse HEAD)"

  # 27a. UNCHANGED overlay pending set is GREEN — a committed baseline, and the
  #      LAST (only) row must still match, which is where a lost trailing
  #      newline would show up.
  MSS_GIT_ROOT="$OVR" _run "$OVR" \
    MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$OVR/ledger.overlay.tsv" \
    MANDATORY_STEP_BASE_REF="$OVR_SHA"
  _expect "an unchanged overlay pending set ratchets green" 0 "validate-mandatory-step-signal: OK"

  # 27b. GROWING it is RED.
  printf 'claude/commands/demo.md%sSome ordinary prose%spending%snewly parked, which the ratchet forbids\n' \
    "$TAB" "$TAB" "$TAB" >>"$OVR/ledger.overlay.tsv"
  MSS_GIT_ROOT="$OVR" _run "$OVR" \
    MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$OVR/ledger.overlay.tsv" \
    MANDATORY_STEP_BASE_REF="$OVR_SHA"
  _expect "the overlay pending set is shrink-only too — not a debt parking lot" 1 "PENDING-GREW"
fi

# ---------------------------------------------------------------------------
# 28-30. temperloop#1740 — AN UPSTREAM ROW FOR AN UNADOPTED COMMAND SPEC.
#
# A consumer adopts a SUBSET of the kernel's command specs, so a kernel registry
# row naming one it did not adopt is expected, not broken. 30 is the limit.
# ---------------------------------------------------------------------------
UA="$(_scaffold unadopted)"
_registry "$UA" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
# A kernel registry row naming a spec this tree never adopted.
printf 'claude/commands/never-adopted.md%sStep 1%s**Mandatory for every run:**%stally%ssig/runner.mjs%smandatory_ok%s-%sthe pass emits a per-run tally\n' \
  "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >>"$UA/registry.tsv"
: >"$UA/ledger.tsv"

# 28 FIRST — the baseline. No .kernel-pin means this IS the kernel, so a row
# naming a missing spec is genuinely broken and must stay RED.
_run "$UA"
_expect "without a .kernel-pin a row naming a missing spec is still SPEC-NOT-FOUND" 1 "SPEC-NOT-FOUND"

# 29. WITH a .kernel-pin the same upstream row is tolerated.
printf 'tag v0.0.0\n' >"$UA/.kernel-pin"
_run "$UA"
_expect "a vendoring consumer tolerates an upstream row for an unadopted spec" 0 "did not adopt"

# 30. THE LIMIT. The same missing spec named by the consumer's OWN overlay
#     registry is still broken — the .kernel-pin is not a blanket mute.
#     The kernel registry is reset to the clean fixture first: leaving the row
#     in BOTH files trips REGISTRY-DUPLICATE, which fails for the wrong reason
#     and would prove nothing about the spec check.
_registry "$UA" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
printf 'claude/commands/never-adopted.md%sStep 1%s**Mandatory for every run:**%stally%ssig/runner.mjs%smandatory_ok%s-%sthe pass emits a per-run tally\n' \
  "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$UA/registry.overlay.tsv"
_run "$UA" MANDATORY_STEP_REGISTRY_OVERLAY_FILE="$UA/registry.overlay.tsv"
_expect "an overlay-authored row naming a missing spec is still SPEC-NOT-FOUND" 1 "SPEC-NOT-FOUND"

# ---------------------------------------------------------------------------
# 31. temperloop#1755 — THE HARNESS ITSELF IS HERMETIC.
#
# Structural, not behavioural, and deliberately so: the failure it guards
# cannot be reproduced from inside this suite without writing a file into the
# repo's REAL config dir, which a test must never do. So instead it asserts
# that every MANDATORY_STEP_*_FILE seam the gate reads is pinned inside _run.
# Adding a third config file and forgetting to pin it is exactly how #1755
# shipped — green here, and red in every composed overlay.
# ---------------------------------------------------------------------------
# Read the body once into a variable and match with `case`, rather than piping
# into `grep -q` — lint-pipe-grep-q forbids that shape, and a `case` needs no
# subprocess anyway.
_run_body="$(awk '/^_run\(\) \{/,/^\}/' "$0")"
count_pinned=0
for _v in MANDATORY_STEP_REGISTRY_FILE MANDATORY_STEP_DISCOVERY_FILE \
          MANDATORY_STEP_REGISTRY_OVERLAY_FILE MANDATORY_STEP_DISCOVERY_OVERLAY_FILE \
          MANDATORY_STEP_QUALITY_GATES_FILE; do
  case "$_run_body" in
    *"$_v="*)
    count_pinned=$((count_pinned + 1))
    ;;
  *)
    bad "_run pins every config seam" "$_v is not pinned inside _run — it will resolve to the REAL config file and contaminate every fixture in a composed overlay (temperloop#1755)"
    ;;
  esac
done
if [ "$count_pinned" -eq 5 ]; then
  ok "_run pins every config seam inside the fixture (harness hermeticity)"
fi

echo "== the ratchet reads a SYMLINKED ledger's content, not its link target (temperloop#1787) =="

# In a composed overlay the ledger is a compat SYMLINK into the vendored kernel
# subtree. `git show <ref>:<symlink-path>` returns the link's TARGET TEXT rather
# than the file content -- and exits 0, so a `|| fallback` never fires. The
# baseline then parses to ZERO rows and every current 'pending' row reads as
# newly added, false-failing this shrink-only ratchet on every run.
#
# Every other fixture in this file uses a REAL ledger file, which is exactly why
# the whole suite passed while the gate was broken in every composed consumer.
# These cases use a symlinked ledger on purpose.
if ! command -v git >/dev/null 2>&1; then
  echo "  skip  symlinked-ledger cases — git not available"
else
  SL="$(_scaffold symlinkledger)"
  _registry "$SL" tally sig/runner.mjs 'mandatory_ok: !skipped.length' -
  # The ledger lives under kernel/ and is reached through a compat symlink,
  # mirroring the composed-overlay layout.
  mkdir -p "$SL/kernel"
  printf 'claude/commands/demo.md%sSome ordinary prose%spending%spre-existing debt\n' \
    "$TAB" "$TAB" "$TAB" >"$SL/kernel/ledger.tsv"
  rm -f "$SL/ledger.tsv"
  ln -s kernel/ledger.tsv "$SL/ledger.tsv"
  (
    cd "$SL" || exit 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git add -A
    git commit -qm base
  ) >/dev/null 2>&1
  SL_BASE="$(git -C "$SL" rev-parse HEAD)"

  # The symlink is COMMITTED at the base ref, so the bootstrap exemption does not
  # fire -- which is the whole point. The bug stayed hidden until the symlinks
  # stopped being new: the vendor that created them was exempt, and the gate only
  # broke once that PR MERGED.
  MSS_GIT_ROOT="$SL" _run "$SL" MANDATORY_STEP_BASE_REF="$SL_BASE"
  _expect "an unchanged SYMLINKED ledger ratchets green (link target is not TSV)" 0 "validate-mandatory-step-signal: OK"

  # And the ratchet must say WHICH path it actually compared -- the physical one.
  case "$RUN_OUT" in
    *"kernel/ledger.tsv"*) ok "the ratchet reports the PHYSICAL ledger path it compared" ;;
    *) bad "the ratchet reports the PHYSICAL ledger path it compared" "expected the resolved kernel/ledger.tsv path in the ratchet line, got: $RUN_OUT" ;;
  esac

  # Shrink-only intent must SURVIVE the fix: resolving the path must not also
  # swallow real growth. A fix that turns a false failure into a false pass has
  # traded one silent failure for another.
  printf 'claude/commands/demo.md%s**Mandatory for every run:**%spending%snewly parked through a symlinked ledger\n' \
    "$TAB" "$TAB" "$TAB" >>"$SL/kernel/ledger.tsv"
  MSS_GIT_ROOT="$SL" _run "$SL" MANDATORY_STEP_BASE_REF="$SL_BASE"
  _expect "a NEW pending row through a SYMLINKED ledger still fails" 1 "PENDING-GREW"

  # Fail-closed arm: .kernel-pin present and the ledger under kernel/, but no
  # subtree squash commit reachable. The upstream half of the comparison is
  # UNKNOWN, and the verdict line must SAY so rather than read as fully checked.
  printf 'tag v0.0.0\n' >"$SL/.kernel-pin"
  MSS_GIT_ROOT="$SL" _run "$SL" MANDATORY_STEP_BASE_REF="$SL_BASE"
  case "$RUN_OUT" in
    *"vendored-kernel arm SKIPPED"*) ok "an unreachable subtree squash is ANNOUNCED, not silently treated as checked" ;;
    *) bad "an unreachable subtree squash is ANNOUNCED" "expected a 'vendored-kernel arm SKIPPED' notice, got: $RUN_OUT" ;;
  esac
fi

echo "---"
echo "passed: $pass | failed: $fail"
[ "$fail" -eq 0 ] || exit 1
