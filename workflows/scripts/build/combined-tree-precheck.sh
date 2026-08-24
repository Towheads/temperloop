#!/usr/bin/env bash
#
# build combined-tree pre-check — the deterministic-machinery script that owns the
# Step-4 level-merge-gate UNION check of /build (temperloop#865). When a level
# parks more than one PR, the orchestrator must know BEFORE it enqueues the set
# whether the parked branches merge together cleanly AND still pass the full
# gate suite as a combined tree — not just pairwise-textually (build.md's
# `git merge-tree` hunk probe already covers that), but SEMANTICALLY: two PRs
# each green alone whose *combination* breaks (a new gate + the files it scans,
# a Makefile target registered only in one branch, a `.PHONY` block, …). Today
# those surface only INSIDE GitHub's native merge queue's `merge_group` trial
# branch — an eject → diagnose → rebase → requeue cycle costing ~1h each (the
# Epic-B retro, F#847). This check moves that discovery LEFT of the enqueue,
# where a collision costs one local gate run instead of a queue round-trip.
#
# This is a LOCAL-GIT script by necessity — it materializes the merged union in
# a throwaway worktree and runs the real gate suite against it. That is a
# deliberate departure from gate.sh's no-local-git invariant (temperloop#242):
# gate.sh reads mergeability through the GitHub API precisely so a PR head ref
# never needs to be reachable locally, whereas running the gate SUITE against
# the merged files is impossible without a local tree. Keeping the two apart —
# gate.sh network-pure, this script local-git — preserves gate.sh's invariant
# rather than smuggling local git into it. This script is a sibling of
# worktree.sh (also local-git), not a gate.sh subcommand.
#
#   combined-tree-precheck.sh <repo-root> <branch> <branch> [<branch> ...] [--base <ref>]
#       → build a throwaway detached worktree at <ref> (default origin/main),
#         `git merge --no-ff` each branch into it in the given order, then run
#         the gate suite (scripts/quality-gates.sh) against the merged tree.
#         Fewer than two branches → SKIP (single-PR levels need no union check).
#
# The gate-suite runner is a fixture seam (COMBINED_TREE_SUITE_CMD, default
# `bash scripts/quality-gates.sh`) so a test can inject a synthetic gate with
# zero dependence on the real suite — the same single-seam-per-dependency shape
# gate.sh uses for `_gate_gh`.
#
# Output contract — CLOSED outcome set, one structured JSON line (the
# orchestrator branches on `.outcome`, never parses prose):
#   {"outcome":"CLEAN","branches":[…]}                                exit 0
#   {"outcome":"SKIP","reason":"fewer-than-two-branches","branches":N} exit 0
#   {"outcome":"CONFLICT","branch":"<ref>","branches":[…]}            exit 3
#   {"outcome":"GATE_FAILED","exit_code":N,"output":"<failing gate's own
#     section>","failed_gates":[…],"suite_log":"<path>","branches":[…]} exit 4
#   {"outcome":"ERROR","error":…}                                     exit 1
# Exit codes: 0 CLEAN/SKIP; 1 ERROR (bad input / setup failure); 3 CONFLICT (a
# branch would not merge into the accumulating union — a textual conflict); 4
# GATE_FAILED (the union merged cleanly but the gate suite failed on it — a
# semantic collision, the class this check exists to catch pre-queue). CONFLICT
# names the FIRST branch that failed to merge; a batched union means a later
# branch's conflict may be attributable to any earlier one, so the name is the
# offending merge, not a root-cause claim.
#
# GATE_FAILED reason surfacing (temperloop#880). quality-gates.sh prints each
# gate's output INLINE under a `=== <gate> ===` banner AS IT RUNS, and its
# `FAILED n/N quality gate(s):` roll-up LAST. So on a ~2100-line suite log a
# blind `tail -N` of the stream captures the roll-up — the failing gate's NAME —
# and discards that gate's own `FAIL:` reason, hundreds of lines upstream: the
# gate cried wolf without saying why. Instead this script keeps the WHOLE log
# (outside the throwaway worktree, which the EXIT trap deletes), reads the
# roll-up's named gates back out of it, and returns each named gate's OWN
# section as `.output`, alongside `.failed_gates` (the names, machine-readable)
# and `.suite_log` (the retained full log's path). An unexpected suite-output
# shape falls back to the old tail rather than an empty reason.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }
command -v git >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"git not found"}'; exit 1; }

# --- fixture seam ------------------------------------------------------------
# The gate-suite command run against the merged worktree. Default = the repo's
# single-source-of-truth static gate set (== CI's `checks` job). Tests override
# it with a synthetic gate. It is a TRUSTED config string (never user input),
# eval'd exactly as quality-gates.sh eval's its own gate command lines.
: "${COMBINED_TREE_SUITE_CMD:=bash scripts/quality-gates.sh}"

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as gate.sh / worktree.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: combined-tree-precheck.sh <repo-root> <branch> <branch> [<branch> ...] [--base <ref>]"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate the repo root: must exist, be a git work tree, and BE the
# toplevel (the worktree is added relative to it). Mirrors worktree.sh.
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || die "repo-root '$arg' does not exist"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "repo-root '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || die "repo-root '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$repo"
}

# Build a JSON array of the branch list once, reused across every outcome line.
_branches_json() { printf '%s\n' "$@" | jq -R . | jq -cs .; }

# --- GATE_FAILED reason extraction (temperloop#880) --------------------------
# Budgets, deliberately plain constants rather than operator settings: the JSON
# is a diagnostic hand-off, and the FULL log is always retained at `.suite_log`,
# so there is nothing here an operator would need to tune per repo.
_CTP_TAIL_LINES=40          # the pre-#880 blind tail — now the FALLBACK only
_CTP_SECTION_MAX_LINES=160  # per-gate section budget inside the JSON
_CTP_SECTION_HEAD_LINES=10  # ... kept from the head when a section is elided

# Read a whole suite log on stdin; report on the gate(s) the trailing
# `FAILED n/N quality gate(s):` roll-up names.
#   $1 = names     → one failing gate name per line
#   $1 = sections  → each failing gate's own inline `=== <gate> ===` section,
#                    blank-line separated, each capped at _CTP_SECTION_MAX_LINES
#                    (head kept + tail kept, the elision marked inline — the
#                    untruncated text is always in the retained log).
# Prints NOTHING and exits 1 when the log carries no recognizable roll-up, or
# when no named gate's banner can be found back in the log. That is the caller's
# cue to fall back to the blind tail, so an unexpected suite-output shape
# degrades to the pre-#880 behaviour instead of an empty reason.
_ctp_gate_report() {
  awk -v mode="$1" -v max="$_CTP_SECTION_MAX_LINES" -v keephead="$_CTP_SECTION_HEAD_LINES" '
    { line[NR] = $0 }
    END {
      # The roll-up is the LAST such line — a nested suite run inside a gate
      # could print one of its own, and the outermost one is ours.
      for (i = NR; i >= 1; i--)
        if (line[i] ~ /^FAILED [0-9]+\/[0-9]+ quality gate\(s\):$/) { summary = i; break }
      if (!summary) exit 1
      for (i = summary + 1; i <= NR; i++) {
        if (line[i] !~ /^  - /) break
        gate[++n] = substr(line[i], 5)
      }
      if (!n) exit 1
      if (mode == "names") { for (g = 1; g <= n; g++) print gate[g]; exit 0 }
      for (g = 1; g <= n; g++) {
        # Exact string match, never a regex: a gate name is a full command line
        # and may carry regex metacharacters.
        hdr = "=== " gate[g] " ==="
        start = 0
        for (i = 1; i < summary; i++) if (line[i] == hdr) { start = i; break }
        if (!start) continue
        end = summary - 1
        for (i = start + 1; i < summary; i++) if (line[i] ~ /^=== .+ ===$/) { end = i - 1; break }
        while (end > start && line[end] == "") end--
        if (emitted++) print ""
        span = end - start + 1
        if (span > max) {
          for (i = start; i < start + keephead; i++) print line[i]
          printf "... [%d line(s) elided — the untruncated section is in the retained suite log] ...\n", span - max
          for (i = end - max + keephead + 1; i <= end; i++) print line[i]
        } else {
          for (i = start; i <= end; i++) print line[i]
        }
      }
      if (!emitted) exit 1
    }
  '
}

# Throwaway-worktree teardown. The paths live at SCRIPT scope (not as
# cmd_precheck locals) so the EXIT trap — which fires AFTER cmd_precheck has
# returned and its locals are gone — can still reach them under `set -u`. Always
# torn down: on CLEAN, CONFLICT, GATE_FAILED, or a die() (exit 1 fires the trap).
_CTP_WT=""
_CTP_REPO=""
# shellcheck disable=SC2317
_ctp_cleanup() {
  [ -n "$_CTP_WT" ] || return 0
  git -C "$_CTP_REPO" worktree remove --force "$_CTP_WT" >/dev/null 2>&1 || rm -rf "$_CTP_WT"
  git -C "$_CTP_REPO" worktree prune >/dev/null 2>&1 || true
}

cmd_precheck() {
  local repo="$1" base="$2"; shift 2
  local branches=("$@") brs_json
  brs_json="$(_branches_json "${branches[@]}")"

  # Fewer than two branches → nothing to combine. A single-PR level skips the
  # whole check (acceptance #3); the orchestrator may also just not call us, but
  # a defensive SKIP lets it invoke unconditionally.
  if [ "${#branches[@]}" -lt 2 ]; then
    jq -cn --argjson n "${#branches[@]}" '{outcome:"SKIP", reason:"fewer-than-two-branches", branches:$n}'
    return 0
  fi

  # The base and every branch must resolve to a commit before we touch a
  # worktree — a bad ref should be a clean ERROR, not a half-built worktree.
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || die "base ref '$base' not found in $repo"
  local b
  for b in "${branches[@]}"; do
    git -C "$repo" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1 \
      || die "branch ref '$b' not found in $repo"
  done

  # Throwaway detached worktree at the base. It shares the repo's object store
  # (a linked worktree), so every branch ref above is reachable from it.
  local wt
  wt="$(mktemp -d "${TMPDIR:-/tmp}/combined-tree.XXXXXX")" || die "mktemp failed"
  # Resolve the throwaway root PHYSICALLY, before anything records or uses it
  # (temperloop#773). On macOS `$TMPDIR` is `/var/folders/…`, and `/var` is a
  # symlink to `/private/var` — so the mktemp name is a LOGICAL spelling of a
  # path whose physical spelling differs. The gate suite then runs with that
  # logical cwd while any script inside it that resolves a path with `pwd -P` /
  # `cd -P` reports the physical one, and a test comparing the two spellings of
  # the same file fails on string inequality alone. That is a false GATE_FAILED
  # for EVERY multi-PR level — which /build's risk trigger (d) treats as
  # unappealable, so batch merge is blocked and levels merge one PR at a time
  # (the transiently-red `main` of temperloop#1678). Canonicalizing HERE is the
  # class fix: the whole suite sees one spelling, so no individual test has to
  # normalize defensively to survive this worktree.
  wt="$(abs_dir "$wt")" || die "could not resolve throwaway worktree path"
  # rmdir the empty mktemp dir so `git worktree add` (which wants to create it)
  # does not error on an existing path; keep the name for the add.
  rmdir "$wt" 2>/dev/null || true

  # Register the worktree with the script-scope teardown before adding it, so a
  # die() between here and the add still triggers cleanup.
  _CTP_WT="$wt"; _CTP_REPO="$repo"
  trap _ctp_cleanup EXIT

  git -C "$repo" worktree add --detach "$wt" "$base" >/dev/null 2>&1 \
    || die "worktree add at base '$base' failed"

  # Merge each branch into the accumulating union. A non-zero merge is a textual
  # conflict — abort it and report the offending branch. --no-ff keeps each a
  # real merge (so conflicts surface exactly as they would in the queue's
  # merge_group trial branch).
  for b in "${branches[@]}"; do
    if ! git -C "$wt" merge --no-ff --no-edit "$b" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      jq -cn --arg branch "$b" --argjson brs "$brs_json" \
        '{outcome:"CONFLICT", branch:$branch, branches:$brs}'
      return 3
    fi
  done

  # The union merged cleanly. Run the FULL gate suite against it — this is where
  # a semantic collision (green-alone, red-combined) surfaces. Run with cwd =
  # the merged worktree; quality-gates.sh resolves its own repo root, so every
  # `make` target still resolves from the worktree (its own design promise).
  local suiteout rc
  set +e
  suiteout="$(cd "$wt" && eval "$COMBINED_TREE_SUITE_CMD" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    local logfile gate_names gates_json out_text
    # Persist the WHOLE suite log OUTSIDE the throwaway worktree. _ctp_cleanup
    # removes $wt on EXIT, so a log written under it would be gone by the time
    # anyone followed the path we return — hence TMPDIR, not $wt. This file is
    # deliberately LEFT BEHIND (it is the hand-off); the OS reaps TMPDIR.
    logfile="$(mktemp "${TMPDIR:-/tmp}/combined-tree-suite.XXXXXX" 2>/dev/null)" || logfile=""
    if [ -n "$logfile" ]; then
      printf '%s\n' "$suiteout" > "$logfile" 2>/dev/null || logfile=""
    fi

    # The failing gate's OWN section, not a blind tail of the stream (see the
    # header's "GATE_FAILED reason surfacing" note).
    gate_names="$(printf '%s\n' "$suiteout" | _ctp_gate_report names)" || gate_names=""
    out_text="$(printf '%s\n' "$suiteout" | _ctp_gate_report sections)" || out_text=""
    if [ -z "$out_text" ]; then
      # Graceful fallback: no recognizable roll-up, or a named gate whose banner
      # isn't in the log (a suite that isn't quality-gates.sh, a test fixture, a
      # future output-shape change). Old behaviour beats an empty reason.
      out_text="$(printf '%s' "$suiteout" | tail -"$_CTP_TAIL_LINES")"
    fi
    gates_json="$(printf '%s' "$gate_names" | jq -R . | jq -cs 'map(select(. != ""))')"

    # New fields are strictly ADDITIVE — `outcome`/`exit_code`/`output`/
    # `branches` and exit 4 are unchanged, so /build Step 4a.5 and gate.sh keep
    # working untouched. `suite_log` is "" when the log could not be persisted.
    jq -cn --arg out "$out_text" --argjson code "$rc" --argjson brs "$brs_json" \
      --argjson gates "$gates_json" --arg log "$logfile" \
      '{outcome:"GATE_FAILED", exit_code:$code, output:$out, branches:$brs,
        failed_gates:$gates, suite_log:$log}'
    return 4
  fi

  jq -cn --argjson brs "$brs_json" '{outcome:"CLEAN", branches:$brs}'
  return 0
}

# --- dispatch ----------------------------------------------------------------
# Source-guard: when sourced by a test (BASH_SOURCE != $0) skip dispatch so the
# cmd_* functions and the seam are callable directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -ge 1 ] || usage
  repo_arg="$1"; shift
  base="origin/main"
  branch_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || usage
        base="$2"; shift 2 ;;
      --base=*)
        base="${1#--base=}"; shift ;;
      --*) usage ;;
      *) branch_args+=("$1"); shift ;;
    esac
  done
  repo="$(resolve_repo "$repo_arg")"
  cmd_precheck "$repo" "$base" "${branch_args[@]}"
fi
