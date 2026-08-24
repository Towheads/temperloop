#!/usr/bin/env bash
# description: build a private, disposable evaluation testbed of this repo, then hand off to `temperloop init`
#
# testbed.sh — `temperloop testbed` (epic temperloop#1117, item
# testbed-command / #1229): the ONE command that turns "I'd like to evaluate
# temperloop, but not on my real repo" into a private, disposable copy of
# that repo you can point the rest of the ladder at.
#
# REGISTRATION IS FILE PRESENCE. There is no dispatch-table edit anywhere:
# `bin/temperloop`'s DISPATCH MODEL (its own header) discovers any
# `bin/subcommands/<name>.sh` as `temperloop <name>` the moment the file
# exists, and reads the `# description:` line above for `temperloop help`
# and for the docs site's subcommand-reference table
# (workflows/scripts/docs/sources/cli.py, the same convention). Those two
# lines — the file, and its description header — ARE this subcommand's
# registration and its discoverability wiring.
#
# THIN WIRING OVER TWO LANDED SEAMS — this script is their FIRST and, today,
# ONLY call site, and it adds NO parallel logic of its own (the bar
# bin/subcommands/init.sh:18-32 sets for its own three seams):
#   1. the machine-scoped artifact record
#      (workflows/scripts/testbed/record.sh, schema 1) — the append-only,
#      per-step-atomically-flushed record of every artifact this run creates
#      outside this machine. This script calls `testbed_record_add` /
#      `testbed_record_mark_step` and never invents a parallel record
#      format, a second state file, or its own idea of what "how far did it
#      get" means. Teardown and `/promote` (later items in this epic) are
#      the readers.
#   2. the source-provider seam (workflows/scripts/testbed/source.sh) —
#      `describe()` / `preflight_checks()` / `produce_git(dest)` /
#      `produce_issues(dest)`. The driver below calls those four functions
#      and NOTHING ELSE decides what a source is or how it is materialized.
#
# NO `case` ON PROVIDER KIND — THE POINT OF THE SEAM. Search this file: the
# provider kind is only ever a STRING passed through to the four seam
# functions. There is no `case "$source_kind"`, no per-provider branch, no
# "if mirror-from-repo then ... else ..." anywhere. That per-provider branch
# is precisely what source.sh's four-function split exists to eliminate
# downstream (see its header), so the second provider
# (`materialize-from-seed`, a later item) lands by defining its own four
# functions — this file does not change at all. An unknown kind is refused
# by the seam's own `testbed_source__require` guard, naming the provider and
# the missing op, rather than by a validation `case` here that would have to
# be edited for every new provider.
#
# THE DRIVER IS FIXED. The step order below never varies by provider, by
# flag, or by outcome:
#
#     describe
#       -> union of preflight_checks (all reads)
#         -> consent
#           -> create the testbed repository -> FLUSH
#             -> produce_git                 -> FLUSH
#               -> produce_issues            -> FLUSH
#                 -> handoff
#
# Each FLUSH is a record.sh call made the instant that step actually
# completed — never batched, never anticipated. That is what makes a run
# killed between steps ENUMERABLE: the record shows exactly how far it got,
# so teardown can find and delete a half-built testbed instead of leaving an
# orphaned private repository nobody can name.
#
# PRE-FLIGHT IS ALL READS, AND IT IS A UNION. The driver's own checks (gh
# present + authenticated; a resolvable destination owner; a collision-free
# destination name) are unioned — deduped by function name — with whatever
# `preflight_checks()` yields for this provider, and every one of them is
# run BEFORE the first mutating call. Every check is a read (`command -v`,
# `gh auth status`, `gh api user`, `gh repo view`, `git rev-parse`), so a
# failed pre-flight exits having created NOTHING, anywhere. A driver check
# fails with `cannot proceed — <fix>`; a provider check fails with
# `skipped — <fix>` (source.sh's own established wording). Either way the
# line names the fix, and the run stops on the first failure rather than
# piling a second, confusing error on top of the real one.
#
# CONSENT IS A HARD GATE, NOT A COURTESY. `try --demo` established the
# guard (refuse on a non-tty stdin with no `--yes`, so a curious stranger
# cannot silently burn spend); this command carries it to a materially
# bigger blast radius — it creates a REAL private GitHub repository, pushes
# a full mirror of your history into it, and copies your open issues. So:
# an explicit y/N confirmation, or `--yes`; and on a non-tty stdin with no
# `--yes` it REFUSES outright rather than assuming (bin/subcommands/tests/
# test_testbed.sh asserts exactly that). Silence is never consent.
#
# --dry-run PERFORMS ZERO WRITES, STRUCTURALLY. It runs describe +
# pre-flight (reads), prints exactly what a real run would create, prints
# the same handoff block, and exits — without ever reaching the consent
# gate (there is nothing to consent to when nothing is created), without a
# single mutating `gh` or `git` call, and without touching the record file.
# test_testbed.sh proves that the way test_try.sh does: a fake `gh` AND a
# fake `git` on PATH that log every call they see, plus a before/after file-
# tree diff of both the source checkout and the XDG state dir — never by
# asserting intent.
#
# WHY THIS `cd`s TO THE SOURCE TOPLEVEL (load-bearing, not tidiness). The
# driver resolves `--dir` to its git toplevel and `cd`s there ONCE, then
# folds it (alongside `--seed-dir`) into the single provider-scoped
# `provider_dir_arg` every seam call below receives (see "PROVIDER-SCOPED
# SOURCE ARGUMENT RESOLUTION" immediately below). A provider may legitimately
# stash per-run state while enumerating its checks (mirror-from-repo stashes
# the source dir so the check functions it names can stay parameterless, per
# the seam contract), and any capture of that enumeration's stdout —
# `$(...)`, a pipe, a process substitution — runs it in a SUBSHELL, where
# such a stash is silently discarded and the checks fall back to their `.`
# default. Making `.` genuinely BE the source checkout makes that fallback
# correct by construction, for `mirror-from-repo`.
#
# PROVIDER-SCOPED SOURCE ARGUMENT RESOLUTION (temperloop#1356). This driver
# holds TWO independent CLI-level directory concepts — `--dir` (resolved to
# `.` after the cd above; mirror-from-repo's own "source repository
# directory") and `--seed-dir` (raw, default empty; materialize-from-seed's
# own "which seed directory") — and must hand each provider only the one
# that is actually its own, WITHOUT ever branching on `--source-kind` to
# decide which (see T2 in bin/subcommands/tests/test_testbed.sh, which
# asserts structurally that this file contains no `case` on provider kind).
# The fix routes the decision through the SEAM instead: a single call to
# `testbed_source_dir_arg` (source.sh's fifth seam member) hands the seam
# BOTH values and gets back ONE — the active provider's own `dir_arg()`
# implementation (source.sh) picks whichever of the two is actually its own
# and returns it, ignoring the other. Every seam call below then uses that
# ONE resolved `provider_dir_arg`, restoring the seam's original
# single-directory-argument shape. Before this, the driver threaded its raw
# `$source_dir` (always `.` once resolved, never empty) straight into every
# seam call regardless of kind, so it silently reached materialize-from-seed
# too and overrode that provider's correctly-computed in-tree default from
# any cwd, yielding a `.`-derived testbed name instead of the seed's own.
#
# Usage:
#   testbed.sh [--dir DIR] [--seed-dir DIR] [--source-kind KIND]
#              [--owner OWNER] [--name NAME] [--yes] [--dry-run]
#
#   --dir DIR          The source checkout to build a testbed FROM. Meaningful
#                      to `mirror-from-repo` only (its describe()/produce_git/
#                      produce_issues read a real git checkout at this path).
#                      Default: the current directory. Resolved to its git
#                      toplevel when it is a git working tree.
#   --seed-dir DIR     The seed directory to materialize FROM. Meaningful to
#                      `materialize-from-seed` only. Default: empty, which
#                      lets the provider fall back to its own in-tree default
#                      (workflows/scripts/demo/seed) — see "PROVIDER-SCOPED
#                      SOURCE ARGUMENTS" below for why this is a SEPARATE flag
#                      from --dir rather than the same one reused.
#   --source-kind KIND The source provider (workflows/scripts/testbed/
#                      source.sh). Default: mirror-from-repo. Passed
#                      through to the seam verbatim; an unknown kind is
#                      refused by the seam itself.
#   --owner OWNER      GitHub owner the testbed repository is created under.
#                      Default: the authenticated user (`gh api user`).
#   --name NAME        Testbed repository name. Default: the provider's
#                      `base_name` plus a `-testbed` suffix, uniquified
#                      against what already exists under OWNER (collision-
#                      safe naming is the DRIVER's job, never a provider's —
#                      source.sh's header says so explicitly).
#   --yes              Skip the interactive y/N confirmation. REQUIRED when
#                      stdin is not a tty.
#   --dry-run          Preview only: zero writes of any kind (see above).
#
# Exit codes: 0 = ran to completion (a declined confirmation is a legible,
# successful run, not a failure). 1 = pre-flight refusal, a failed step, or
# a fatal environment error. 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq, and an authenticated `gh`. Unlike
# `try`, there is NO degraded path here: every one of those is required to
# create a repository, mirror history into it, and copy issues, so a missing
# one is a pre-flight refusal that names the fix rather than a partial run.
#
# --teardown MODE (temperloop#1231, epic #1117 Produces 7) — the reader of
# the artifact record this driver writes. Usage:
#
#   testbed.sh --teardown [--repo OWNER/NAME] [--dir DIR] [--id ID]
#              [--yes] [--dry-run]
#
#   --repo OWNER/NAME  The testbed to tear down, explicitly. Default: the
#                      'origin' remote of --dir (default: cwd), read with
#                      `git -C` (never a `cd`) — so this works from ANY
#                      cwd, including inside the testbed's own clone.
#   --id ID            Which recorded entry to remove, when more than one
#                      is recorded at that owner/name. Default: the most
#                      recently created entry.
#
# ONE `gh repo delete` REMOVES EVERY ARTIFACT THE RECORD ENUMERATES,
# ALWAYS, EVEN AFTER A PARTIAL-FAILURE RUN: record.sh's own contract makes
# artifacts.repo_created=true true the instant an entry is born ("creation
# IS the repo-created mutating step"), and the mirrored history and any
# copied issues both live INSIDE that same repository — so deleting it
# removes whatever the record enumerates, whether or not mirror_pushed /
# issues_copied ever flushed true. No branching on which steps finished.
#
# THE delete_repo SCOPE GATE IS LEGIBLE DEGRADATION, NOT A FAILURE.
# `gh auth login`'s default scope set does not include `delete_repo` — so a
# testbed created under an ordinary login has no way to be deleted until
# the operator explicitly grants it. Rather than let `gh repo delete` fail
# opaquely, teardown checks first (workflows/scripts/testbed/scope.sh's
# `testbed_teardown_has_delete_repo_scope`, reused so this isn't
# reimplemented inline anywhere else that needs it, e.g. a CI round-trip
# step): absent, it prints the one-line `gh auth refresh -s delete_repo`
# remedy and exits 0, leaving the record entry untouched for a re-run.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# init.sh (see init.sh's header for why the paths are pinned).
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
RECORD_LIB="$KERNEL_ROOT/workflows/scripts/testbed/record.sh"
SOURCE_LIB="$KERNEL_ROOT/workflows/scripts/testbed/source.sh"
SCOPE_LIB="$KERNEL_ROOT/workflows/scripts/testbed/scope.sh"

if [ ! -f "$RECORD_LIB" ]; then
  echo "testbed.sh: record.sh not found at $RECORD_LIB (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$SOURCE_LIB" ]; then
  echo "testbed.sh: source.sh not found at $SOURCE_LIB (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$SCOPE_LIB" ]; then
  echo "testbed.sh: scope.sh not found at $SCOPE_LIB (broken kernel checkout)" >&2
  exit 1
fi

# All three libraries are SOURCED, never re-implemented. None sets shell
# options at file scope, so this script's own `set -uo pipefail` survives.
# shellcheck source=../../workflows/scripts/testbed/record.sh
. "$RECORD_LIB"
# shellcheck source=../../workflows/scripts/testbed/source.sh
. "$SOURCE_LIB"
# shellcheck source=../../workflows/scripts/testbed/scope.sh
. "$SCOPE_LIB"

usage() {
  cat <<'EOF'
usage: testbed.sh [--dir DIR] [--seed-dir DIR] [--source-kind KIND]
                  [--owner OWNER] [--name NAME] [--yes] [--dry-run]
       testbed.sh --teardown [--repo OWNER/NAME] [--dir DIR] [--id ID]
                  [--yes] [--dry-run]

Builds a private, disposable evaluation copy of a repo — create it,
mirror-push its history, carry its open issues across — then hands off to
`temperloop init` inside the copy.

--dir and --seed-dir are provider-scoped: --dir names the source repository
directory for --source-kind mirror-from-repo (the default provider);
--seed-dir names the seed directory for --source-kind materialize-from-seed.
Only the flag matching the active provider has any effect.

--teardown deletes a testbed created by a prior run and removes its entry
from the machine-scoped artifact record (workflows/scripts/testbed/
record.sh). The target is resolved from --repo OWNER/NAME if given,
otherwise from --dir's (default: cwd) 'origin' remote — so it works from
inside the testbed's own clone, not only from the checkout that created it.
Requires the gh account's delete_repo OAuth scope; without it, teardown
exits 0 and prints the `gh auth refresh -s delete_repo` remedy rather than
failing.
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
source_dir="."
seed_dir_flag=""
source_kind="mirror-from-repo"
owner_flag=""
name_flag=""
assume_yes=0
dry_run=0
teardown_mode=0
repo_flag=""
id_flag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) source_dir="${2:?--dir needs a value}"; shift 2 ;;
    --seed-dir) seed_dir_flag="${2:?--seed-dir needs a value}"; shift 2 ;;
    --source-kind) source_kind="${2:?--source-kind needs a value}"; shift 2 ;;
    --owner) owner_flag="${2:?--owner needs a value}"; shift 2 ;;
    --name) name_flag="${2:?--name needs a value}"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --teardown) teardown_mode=1; shift ;;
    --repo) repo_flag="${2:?--repo needs a value}"; shift 2 ;;
    --id) id_flag="${2:?--id needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "testbed.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency floor — jq and git are needed by the seam calls themselves (the
# record library's read/write, and the provider's own git reads), so they are
# checked before step 1 rather than as pre-flight entries that could not run
# without them. Same `cannot proceed —` wording as every other driver-owned
# refusal below.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "cannot proceed — jq not found on PATH (install jq; the testbed record and the provider seam both parse JSON with it). Nothing was created." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "cannot proceed — git not found on PATH (install git). Nothing was created." >&2
  exit 1
fi

# =============================================================================
# TEARDOWN MODE — a separate leg of this same command (temperloop#1231),
# branching EARLY (before any of the --dir toplevel-resolution/cd, describe,
# pre-flight-union, consent, or four seam calls below) so it can never
# perturb the create-path driver's fixed step order. It shares only the two
# libraries already sourced above (record.sh, scope.sh) and the CLI-level
# --dir/--yes/--dry-run flags; nothing past this block runs on this leg.
#
# Target resolution is via the MACHINE-scoped record, never a tree-relative
# path: --repo OWNER/NAME if given, else --dir's (default: cwd) 'origin'
# remote read with `git -C` (no cd, so this works from ANY cwd — inside the
# testbed's own clone, inside the original source checkout, or a bare
# directory with --repo). record.sh's own key convention (its header,
# "testbeds ... keyed by the CREATED TESTBED's own owner/name") is exactly
# what makes this a zero-filesystem-scan lookup.
#
# Every recorded entry has artifacts.repo_created=true by construction
# (testbed_record_add's own contract: "creation IS the repo-created
# mutating step") — so a SINGLE `gh repo delete` always removes every
# artifact the record enumerates for that entry (the mirrored history and
# any copied issues live inside the repo being deleted), even when
# mirror_pushed/issues_copied never flushed true — a partial-failure run's
# entry tears down exactly like a complete one, no branching on which steps
# finished.
# =============================================================================
if [ "$teardown_mode" -eq 1 ]; then
  echo "== temperloop testbed --teardown =="
  echo

  if [ -n "$repo_flag" ]; then
    case "$repo_flag" in
      */*) teardown_key="$repo_flag" ;;
      *) echo "cannot proceed — --repo must be exactly \"<owner>/<name>\": $repo_flag" >&2; exit 1 ;;
    esac
  else
    _td_origin="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
    teardown_key="$(_testbed_slug_from_remote "$_td_origin")"
    if [ -z "$teardown_key" ]; then
      echo "cannot proceed — could not resolve a testbed owner/name from --dir's ('$source_dir') 'origin' remote. Pass --repo OWNER/NAME, or run this from inside the testbed's own clone." >&2
      exit 1
    fi
  fi

  echo "-- Resolve the target (machine-scoped record: $(testbed_record_file)) --"
  if ! entries_json="$(testbed_record_list "$teardown_key")"; then
    echo "cannot proceed — could not read the testbed record." >&2
    exit 1
  fi
  entry_count="$(jq 'length' <<<"$entries_json")"
  if [ "$entry_count" -eq 0 ]; then
    echo "temperloop testbed --teardown: nothing recorded for $teardown_key — nothing to tear down."
    exit 0
  fi

  if [ -n "$id_flag" ]; then
    entry="$(jq -c --arg i "$id_flag" '[.[] | select(.id == $i)][0] // empty' <<<"$entries_json")"
    if [ -z "$entry" ]; then
      echo "cannot proceed — no entry $id_flag recorded for $teardown_key." >&2
      exit 1
    fi
  else
    # No --id: the most recently created entry. record.sh's list is
    # append-only, so the last element is the newest run.
    entry="$(jq -c '.[-1]' <<<"$entries_json")"
  fi
  entry_id="$(jq -r '.id' <<<"$entry")"
  printf '%s\n' "$entry" | jq -c '.'
  echo

  # -- the delete_repo scope gate: LEGIBLE DEGRADATION, not a failure. -------
  echo "-- delete_repo scope check (scope.sh) --"
  if ! testbed_teardown_has_delete_repo_scope; then
    echo "skipped — gh account lacks the delete_repo scope; run: gh auth refresh -s delete_repo"
    echo "  $teardown_key ($entry_id) was NOT deleted; its record entry was left in place — re-run --teardown after the scope is granted."
    exit 0
  fi
  echo "  [ok]   delete_repo scope present"
  echo

  if [ "$dry_run" -eq 1 ]; then
    echo "[dry-run] would run: gh repo delete $teardown_key --yes"
    echo "[dry-run] would record: testbed_record_remove $teardown_key $entry_id"
    exit 0
  fi

  if [ "$assume_yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      echo "cannot proceed — refusing to run non-interactively without --yes. \`temperloop testbed --teardown\` deletes a REAL private GitHub repository ($teardown_key) — that must never happen on an unattended stdin with nobody answering. Re-run with --yes to confirm, or --dry-run to preview." >&2
      exit 1
    fi
    printf 'Delete %s and its recorded artifacts? [y/N] ' "$teardown_key"
    consent_reply=""
    read -r consent_reply || consent_reply=""
    case "$consent_reply" in
      y|Y|yes|YES) ;;
      *)
        echo "temperloop testbed --teardown: aborted (no confirmation given) — nothing was deleted."
        exit 0
        ;;
    esac
  fi
  echo

  if ! delete_out="$(gh repo delete "$teardown_key" --yes 2>&1)"; then
    echo "testbed.sh: could not delete $teardown_key: $delete_out" >&2
    echo "The record entry ($entry_id) was left in place so a re-run can retry." >&2
    exit 1
  fi
  echo "Deleted $teardown_key"

  if ! testbed_record_remove "$teardown_key" "$entry_id"; then
    echo "testbed.sh: $teardown_key was deleted but its record entry ($entry_id) could NOT be removed — remove it by hand from $(testbed_record_file)." >&2
    exit 1
  fi
  echo "  → $teardown_key ($entry_id) removed from the record"
  echo
  echo "temperloop testbed --teardown: done"
  exit 0
fi

# --- resolve --dir, then cd there (see "WHY THIS cd's" in the header) ------
if ! resolved_dir="$(cd "$source_dir" 2>/dev/null && pwd -P)"; then
  echo "cannot proceed — --dir '$source_dir' does not exist. Nothing was created." >&2
  exit 1
fi
source_top="$(git -C "$resolved_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$source_top" ]; then
  resolved_dir="$(cd "$source_top" && pwd -P)"
fi
cd "$resolved_dir" || {
  echo "cannot proceed — could not enter '$resolved_dir'. Nothing was created." >&2
  exit 1
}
source_dir="."

# --- provider-scoped directory argument (see "PROVIDER-SCOPED DIRECTORY
# ARGUMENT RESOLUTION" in the header) -- resolved via the SEAM's own fifth
# member, never by branching on kind here. Both of this driver's CLI-level
# directory values (--dir's resolved `source_dir`, --seed-dir's raw
# `seed_dir_flag`) are handed to the seam unconditionally; the ACTIVE
# provider's own dir_arg() picks whichever one is actually its own and
# returns it. Every seam call below uses this ONE resolved value, restoring
# the seam's original single-directory-argument arity.
# ---------------------------------------------------------------------------
if ! provider_dir_arg="$(testbed_source_dir_arg "$source_kind" "$source_dir" "$seed_dir_flag")"; then
  echo "cannot proceed — provider \"$source_kind\" could not resolve its own directory argument (see the line above). Nothing was created." >&2
  exit 1
fi

echo "== temperloop testbed =="
echo

# ---------------------------------------------------------------------------
# Step 1 — describe (provider seam). Zero network writes and zero content
# fetching by contract, which is what makes it safe to run before pre-flight
# has passed and before anything exists.
# ---------------------------------------------------------------------------
echo "-- 1. Resolve the source (provider seam: describe) --"
if ! source_desc="$(testbed_source_describe "$source_kind" "$provider_dir_arg")"; then
  echo "cannot proceed — provider \"$source_kind\" could not describe the source (see the line above). Nothing was created." >&2
  exit 1
fi
printf '%s\n' "$source_desc" | jq -c '.'

resolved_kind="$(jq -r '.kind // empty' <<<"$source_desc")"
base_name="$(jq -r '.base_name // empty' <<<"$source_desc")"
provenance_capable="$(jq -r '.provenance_capable // false' <<<"$source_desc")"
promotable="$(jq -r '.promotable // false' <<<"$source_desc")"
if [ -z "$resolved_kind" ] || [ -z "$base_name" ]; then
  echo "cannot proceed — provider \"$source_kind\" returned a describe() payload with no kind/base_name: $source_desc. Nothing was created." >&2
  exit 1
fi

# <describe()-json> -> the resolved source_repo slug, or empty. Named
# extraction of the record's `source_repo` field, read from `describe()`'s
# OWN payload above — the SEAM's data, resolved from the ACTIVE provider's
# own `provider_dir_arg`, never a bare `git remote get-url origin` read in
# the DRIVER's cwd (temperloop#1357). The pre-fix version of this did
# exactly that: identically for both providers, so a materialize-from-seed
# run — which has no source repository, ever — silently captured whatever
# UNRELATED repo the command happened to be run from (a real risk: the
# likely case for someone trying the demo is running it from inside a real
# clone). describe() already resolved this correctly per-provider (mirror-
# from-repo's own `source_dir`; unconditionally null for
# materialize-from-seed, which has no upstream to name) — this driver
# function only reads it, never re-derives it, and never branches on kind.
_testbed_source_identity() {
  jq -r '.source_repo // empty' <<<"$1"
}
source_slug="$(_testbed_source_identity "$source_desc")"
echo

# ---------------------------------------------------------------------------
# Step 2 — pre-flight: the UNION of the driver's own all-reads checks and
# whatever this provider yields, deduped by function name, run in order,
# stopping at the first failure. Nothing below this block has run yet, so a
# refusal here is a genuinely zero-write exit.
# ---------------------------------------------------------------------------

# Driver-owned checks. `gh` is the driver's own dependency (it creates the
# repository), so the driver owns this check rather than assuming some
# provider will happen to declare an equivalent one.
# shellcheck disable=SC2329  # invoked INDIRECTLY, by name, from the pre-flight union loop below — that indirection is the seam's whole point
_testbed_check_gh_available() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "cannot proceed — gh CLI not found on PATH (install it: https://cli.github.com) — \`temperloop testbed\` creates the testbed repository with it" >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "cannot proceed — gh is not authenticated (run: gh auth login)" >&2
    return 1
  fi
}

# Resolved by _testbed_check_destination below, read by every later step.
testbed_owner=""
testbed_name=""

# All-reads check AND the collision-safe uniquification source.sh's header
# assigns to the driver ("describe() yields base_name, NOT a final name —
# collision-safe uniquification against an existing repo is a shared
# DOWNSTREAM concern"). It resolves rather than merely asserts, deliberately:
# the resolution is pure `gh` READS (`gh api user`, `gh repo view`), and
# doing it here is what lets the consent prompt name the EXACT repository
# that will be created instead of a pattern the run might later deviate from.
# shellcheck disable=SC2329  # invoked INDIRECTLY, by name, from the pre-flight union loop below (same as _testbed_check_gh_available above)
_testbed_check_destination() {
  local candidate n
  if [ -n "$owner_flag" ]; then
    testbed_owner="$owner_flag"
  else
    testbed_owner="$(gh api user --jq '.login' 2>/dev/null || true)"
    if [ -z "$testbed_owner" ]; then
      echo "cannot proceed — could not resolve a destination owner from \`gh api user\` (pass --owner OWNER, or run: gh auth login)" >&2
      return 1
    fi
  fi

  if [ -n "$name_flag" ]; then
    if gh repo view "$testbed_owner/$name_flag" >/dev/null 2>&1; then
      echo "cannot proceed — $testbed_owner/$name_flag already exists (pass a different --name, or drop --name and let testbed pick a free name)" >&2
      return 1
    fi
    testbed_name="$name_flag"
    return 0
  fi

  candidate="${base_name}-testbed"
  n=2
  while gh repo view "$testbed_owner/$candidate" >/dev/null 2>&1; do
    if [ "$n" -gt 50 ]; then
      echo "cannot proceed — every candidate from ${base_name}-testbed through ${base_name}-testbed-50 is taken under $testbed_owner (pass --name to choose one)" >&2
      return 1
    fi
    candidate="${base_name}-testbed-${n}"
    n=$((n + 1))
  done
  testbed_name="$candidate"
}

echo "-- 2. Pre-flight (all reads — nothing is created until every check passes) --"

preflight_fns=()
# Dedupe by function NAME: a provider that declares a check the driver
# already owns contributes it once, not twice.
_testbed_preflight_add() {
  local existing
  for existing in ${preflight_fns[@]+"${preflight_fns[@]}"}; do
    [ "$existing" = "$1" ] && return 0
  done
  preflight_fns+=("$1")
}

_testbed_preflight_add _testbed_check_gh_available

# The provider's own half of the union. Its stdout is a list of zero-arg
# function NAMES; the driver runs whatever it yields and never inspects the
# names to decide which apply.
if ! provider_checks="$(testbed_source_preflight_checks "$source_kind" "$provider_dir_arg")"; then
  echo "cannot proceed — provider \"$source_kind\" could not enumerate its pre-flight checks (see the line above). Nothing was created." >&2
  exit 1
fi
while IFS= read -r _fn; do
  [ -n "$_fn" ] || continue
  _testbed_preflight_add "$_fn"
done <<EOF
$provider_checks
EOF

# Last, because it is the only check that reaches GitHub for repo state and
# a broken/unauthenticated gh should be reported as such first.
_testbed_preflight_add _testbed_check_destination

for _fn in ${preflight_fns[@]+"${preflight_fns[@]}"}; do
  if "$_fn"; then
    echo "  [ok]   $_fn"
  else
    echo "  [FAIL] $_fn"
    echo
    echo "cannot proceed — pre-flight failed; nothing was created. Every check above is a read, so this run made no changes anywhere — fix the condition named on the line above and re-run." >&2
    exit 1
  fi
done
echo

testbed_slug="$testbed_owner/$testbed_name"
testbed_url="https://github.com/$testbed_slug"

# ---------------------------------------------------------------------------
# The handoff block — printed by BOTH the dry-run and the real path, so a
# preview shows exactly the block a real run ends with. Unmissable final-block
# shape, per temperloop#781 (init.sh's Section 5): a banner, the artifact URL
# printed IN FULL, the literal copy-pasteable commands, and a stable
# `next step:` marker line. Nothing is ever printed after it.
# ---------------------------------------------------------------------------
_testbed_handoff() {
  local banner="$1"
  echo "temperloop testbed: done"
  echo
  echo "-- Handoff --"
  echo "================================================================"
  echo "  $banner"
  echo "================================================================"
  echo
  echo "Testbed: $testbed_url"
  echo
  echo "Clone it, cd into it, and run temperloop init THERE (not here):"
  echo
  echo "    git clone $testbed_url.git"
  echo "    cd $testbed_name"
  echo "    temperloop init"
  echo
  echo "next step: temperloop init — run it inside the clone above. The testbed is a"
  # Branches on whether describe() resolved a REAL source repository
  # ($source_slug — seam DATA, per describe()'s own `source_repo` field),
  # never on provider kind: a mirror-from-repo run with no origin configured
  # takes the same "no repo to reassure about" leg a seed run always takes,
  # and a seed run stays silent on "your real repo" — there is none to make
  # a claim about (temperloop#1357).
  if [ -n "$source_slug" ]; then
    echo "  throwaway: everything init proposes lands there, and your real repo"
    echo "  ($source_slug) is never touched."
  else
    echo "  throwaway, materialized fresh from tracked demo content — there is no"
    echo "  real repository of yours in the loop for this run at all."
  fi
  echo "================================================================"
}

# ---------------------------------------------------------------------------
# Step 3 — consent. Skipped entirely on --dry-run: nothing is created, so
# there is nothing to consent to, and a preview must stay runnable in CI and
# in a pipe.
# ---------------------------------------------------------------------------
echo "-- 3. Consent (this creates a REAL private GitHub repository) --"
echo "About to create:"
echo "  testbed repo : $testbed_slug (private)"
echo "  source       : ${source_slug:-(no source repository)} via provider \"$resolved_kind\""
echo "  steps        : create repo -> mirror-push git history -> copy open issues"
echo "  provenance   : provenance_capable=$provenance_capable  promotable=$promotable"
echo "  record       : $(testbed_record_file)"
echo

if [ "$dry_run" -eq 1 ]; then
  echo "consent: skipped (--dry-run — nothing is created, so there is nothing to consent to)"
  echo
  echo "-- 4. Create the testbed repository --"
  echo "[dry-run] would run: gh repo create $testbed_slug --private"
  echo "[dry-run] would record: testbed_record_add $testbed_slug $resolved_kind ${source_slug:-<null>} $promotable"
  echo
  echo "-- 5. Mirror the git history (provider seam: produce_git) --"
  echo "[dry-run] would run: produce_git $testbed_url.git"
  echo "[dry-run] would record: testbed_record_mark_step ... mirror_pushed"
  echo
  echo "-- 6. Copy the open issues (provider seam: produce_issues) --"
  echo "[dry-run] would run: produce_issues $testbed_slug"
  echo "[dry-run] would record: testbed_record_mark_step ... issues_copied"
  echo
  _testbed_handoff "DRY RUN — NOTHING WAS CREATED; THIS IS THE HANDOFF A REAL RUN PRINTS"
  exit 0
fi

if [ "$assume_yes" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "cannot proceed — refusing to run non-interactively without --yes. \`temperloop testbed\`" >&2
    echo "  creates a REAL private GitHub repository, mirror-pushes your full history into it," >&2
    echo "  and copies your open issues — that must never happen on an unattended stdin with" >&2
    echo "  nobody answering. Re-run with --yes to confirm, or --dry-run to preview." >&2
    echo "  Nothing was created." >&2
    exit 1
  fi
  printf 'Create %s and mirror this repo into it? [y/N] ' "$testbed_slug"
  consent_reply=""
  read -r consent_reply || consent_reply=""
  case "$consent_reply" in
    y|Y|yes|YES) ;;
    *)
      echo "temperloop testbed: aborted (no confirmation given) — nothing was created."
      exit 0
      ;;
  esac
fi
echo

# ---------------------------------------------------------------------------
# Step 4 — create the testbed repository, then FLUSH. testbed_record_add IS
# the repo_created flush: the record entry is born with that artifact already
# true, so there is never a moment where a created repository has no record.
# ---------------------------------------------------------------------------
echo "-- 4. Create the testbed repository --"
# gh's own credential helper backs the plain-HTTPS mirror push in step 5,
# regardless of the caller's git_protocol setting — best-effort: a caller
# whose git is already credentialed needs no setup, and a failure here
# surfaces on the push itself.
gh auth setup-git >/dev/null 2>&1 || true
if ! create_out="$(gh repo create "$testbed_slug" --private 2>&1)"; then
  echo "testbed.sh: could not create $testbed_slug: $create_out" >&2
  echo "Nothing was recorded — the repository was never created." >&2
  exit 1
fi
echo "Created $testbed_url (private)"

if ! record_id="$(testbed_record_add "$testbed_slug" "$resolved_kind" "$source_slug" "$promotable")"; then
  echo "testbed.sh: $testbed_slug was created but could NOT be recorded — delete it by hand:" >&2
  echo "  gh repo delete $testbed_slug --yes" >&2
  exit 1
fi
echo "  → $testbed_slug ($record_id) repo_created recorded"
echo

# ---------------------------------------------------------------------------
# Step 5 — produce_git, then FLUSH. A failure here leaves a recorded entry
# with mirror_pushed=false: enumerable and removable by teardown, never a
# silent orphan.
# ---------------------------------------------------------------------------
echo "-- 5. Mirror the git history (provider seam: produce_git) --"
if ! testbed_source_produce_git "$source_kind" "$testbed_url.git" "$provider_dir_arg"; then
  echo "testbed.sh: produce_git failed — $testbed_slug exists and IS recorded ($record_id) with mirror_pushed=false, so teardown can still find and remove it." >&2
  exit 1
fi
echo "Mirror pushed to $testbed_url"
testbed_record_mark_step "$testbed_slug" "$record_id" mirror_pushed
echo

# ---------------------------------------------------------------------------
# Step 6 — produce_issues, then FLUSH. The provider stamps its own
# `copied from <owner>/<repo>#<N>` provenance line inside produce_issues;
# this driver never adds one, so a provider with no upstream issue to cite
# simply never emits one.
# ---------------------------------------------------------------------------
echo "-- 6. Copy the open issues (provider seam: produce_issues) --"
if ! testbed_source_produce_issues "$source_kind" "$testbed_slug" "$provider_dir_arg"; then
  echo "testbed.sh: produce_issues failed — $testbed_slug exists and IS recorded ($record_id) with issues_copied=false, so teardown can still find and remove it." >&2
  exit 1
fi
testbed_record_mark_step "$testbed_slug" "$record_id" issues_copied
echo

_testbed_handoff "YOUR EVALUATION TESTBED IS READY"
exit 0
