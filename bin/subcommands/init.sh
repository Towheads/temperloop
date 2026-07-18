#!/usr/bin/env bash
# description: bootstrap .temperloop/config; propose tree changes via PR; consented apply of API-state (required check, fnd: labels, opt-in board)
#
# init.sh — `foundation init`: opt-in, reviewable adoption (foundation #765
# Epic D "newcomer experience", item foundation-init / #854).
#
# Thin wiring over three landed seams — this script is their ONLY call
# site, it adds no parallel logic of its own:
#   1. the conventions probe (workflows/scripts/probe/conventions-probe.sh,
#      contract: workflows/scripts/lib/conventions_probe.contract.md,
#      schema 1) — read-only detection of the target repo's conventions.
#   2. the proposal-PR generator (workflows/scripts/proposal/proposal-pr.sh)
#      — the ONLY path by which this script ever writes to the target
#      repo's TREE. Every tree change (`.temperloop/config`, an optional
#      `workflows/scripts/board/boards.conf` entry) rides a reviewable PR;
#      nothing is ever committed straight to the default branch.
#   3. a CONSENTED APPLY STEP, owned by this script (there is no landed
#      generator for it): explicit, per-action confirmation before any
#      API-STATE write — a required status check, the `fnd:`/funnel label
#      set, and (only on the separate --provision-board opt-in) a
#      Projects-v2 board. Each is a plain `gh` call; --dry-run or a denied
#      prompt performs zero of them.
#
# `foundation init` is the SOLE WRITER of `.temperloop/config` — no other
# subcommand (this repo's `eject`, once it lands, only READS it) ever
# creates or edits that file. Every side effect this script produces (a
# label, a required-check setting, a proposal branch/PR, a board) is
# recorded in `.temperloop/config`'s `installs` array — the exact set
# `foundation eject` reverts. Re-running this script MERGES into that
# array rather than clobbering it (see "round-trip" below), and an install
# already recorded from a prior run (or already present on the remote,
# e.g. a label that already existed) is never re-recorded or re-applied.
#
# TRACKER MODE is a THIN RENDER, not a second config store: the functional
# artifact the board adapter (workflows/scripts/board/lib/board.sh) reads
# is `boards.conf`, in its own documented format and discovery path — see
# `workflows/scripts/board/boards.conf.example`. This script only RENDERS
# the `board.<N>.*` lines for the chosen mode and, when the target repo has
# already adopted the board toolkit (a `workflows/scripts/board/` dir
# exists), proposes appending them to that repo's `boards.conf` via the
# SAME proposal-PR generator (still tree-only, still reviewable). When the
# toolkit isn't present yet, the rendered entry is only recorded in
# `.temperloop/config` (`tracker.boards_conf_entry`) for the operator to
# apply by hand later — `.temperloop/config` itself is NEVER read by the
# adapter, so there is no risk of two config stores disagreeing.
# Issues-only (`board.<N>.backend=issues`) is the default tracker mode —
# opt into a real Projects-v2 board with `--tracker-mode projects
# --provision-board`.
#
# BOOTSTRAP ORDERING NOTE (a known, accepted limitation): the proposal PR
# this script opens carries `.temperloop/config`'s content as committed
# BEFORE that PR's own outcome (its branch/PR number) is known — a
# PR can't describe itself before it exists. This script resolves it with
# a second pass: once the first `proposal-pr.sh open` call returns
# PR_OPENED/EXISTS, it folds a `{"type":"proposal_pr",...}` install entry
# for THIS run into `.temperloop/config` and calls the SAME generator a
# second time (same branch, --force) so the version that actually lands
# is self-describing. A --dry-run or NO_CHANGES first pass skips this
# second pass — there is no PR yet to describe.
#
# Epic E soft seam (baseline-snapshot): 'present' is decided purely by
# kernel/bin/subcommands/baseline-snapshot.sh existing next to this file —
# the dispatcher's own file-discovery mechanism IS the capability probe,
# so this script never hand-maintains a second "is it there" check. The
# invocation contract is one line: no args, exit 0 = snapshot written.
# Absent -> "skipped — baseline-snapshot unavailable", and init continues
# either way; this is a soft seam that never blocks init.
#
# PARTIAL-RUN RECOVERY (temperloop#414): a run that dies anywhere from Step
# 3's proposal-pr.sh call onward (killed process, failed push, failed `gh pr
# create`) leaves the checkout on the proposal branch with no memory of what
# branch it came from. This script writes an untracked `.temperloop/.recovery.json`
# ({"original_branch":...,"proposal_branch":...}) immediately before that
# call and deletes it immediately after the call succeeds (whatever the
# outcome) — so the marker survives on disk exactly when, and only when, a
# run was interrupted mid-switch. `foundation eject` (kernel/bin/subcommands/
# eject.sh) is the reader: it restores `original_branch` and deletes the
# stray `proposal_branch` when it finds the marker and the checkout is still
# sitting on that branch. A run whose HEAD is detached, or that never
# switches branch (already on it), writes no marker — nothing to restore.
#
# Usage:
#   init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
#           [--branch NAME] [--base BRANCH] [--remote NAME]
#           [--tracker-mode issues|projects] [--board N]
#           [--provision-board]
#           [--yes-required-check | --no-required-check]
#           [--yes-labels | --no-labels]
#           [--yes-board | --no-board]
#           [--dry-run]
#
#   --dir DIR             Git checkout to initialize. Default: current dir.
#   --gh-repo OWNER/REPO  Forwarded to the probe; also the repo this
#                          script's own `gh` calls target. Default:
#                          inferred by the probe from the origin remote.
#   --no-network           Forwarded to the probe; ALSO forces every
#                          consented-apply action to skip (no gh_repo
#                          resolution is trustworthy offline).
#   --timeout SECS         Forwarded to the probe. Default: 10.
#   --branch NAME           Proposal branch name. Default:
#                          "foundation-init/config" — a single stable,
#                          re-usable branch: re-running this script force-
#                          updates the same open PR rather than opening a
#                          new one each time.
#   --base BRANCH          Forwarded to the proposal generator. Default:
#                          the target repo's own default branch.
#   --remote NAME           Forwarded to the proposal generator. Default: origin.
#   --tracker-mode MODE     "issues" (default) or "projects". Only "issues"
#                          needs no further opt-in — see --provision-board.
#   --board N               Logical board number the rendered boards.conf
#                          entry uses. Default: carried forward from an
#                          existing .temperloop/config, else 1.
#   --provision-board       Explicit opt-in to ALSO offer provisioning a
#                          real Projects-v2 board via the consented apply
#                          step. No-op unless --tracker-mode projects.
#                          Absent this flag, board provisioning is never
#                          even offered — the strongest form of "opt-in".
#   --yes-<action> / --no-<action>
#                          Pre-answer one of the three consented-apply
#                          actions (required-check / labels / board)
#                          instead of an interactive prompt. With none of
#                          these AND no interactive tty, the default is
#                          "no" for every action — nothing lands without
#                          explicit consent, ever.
#   --dry-run               Forwarded to the proposal generator (local
#                          commit only, nothing pushed, no PR opened) AND
#                          skips the consented-apply step entirely (zero
#                          gh mutation calls of any kind).
#
# Exit codes: 0 = ran to completion (even if every apply action was
# declined — that is a legible, successful run, not a failure). 1 = fatal
# usage/environment error (bad --dir, probe/generator missing or failing).
# 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq (hard requirements, mirroring the
# probe and generator this script wraps). `gh` is optional — its absence
# degrades only the consented-apply step (every action reports "skipped").
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# try.sh (kernel/bin/subcommands/try.sh's own header comment).
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
PROBE="$KERNEL_ROOT/workflows/scripts/probe/conventions-probe.sh"
PROPOSAL="$KERNEL_ROOT/workflows/scripts/proposal/proposal-pr.sh"
BASELINE_SNAPSHOT="$SUBCOMMAND_DIR/baseline-snapshot.sh"

if [ ! -f "$PROBE" ]; then
  echo "init.sh: conventions-probe.sh not found at $PROBE (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$PROPOSAL" ]; then
  echo "init.sh: proposal-pr.sh not found at $PROPOSAL (broken kernel checkout)" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "init.sh: jq not found on PATH" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "init.sh: git not found on PATH" >&2; exit 1; }

# Test-double seam (mirrors try.sh's TRY_GH_BIN / funnel-drive.sh's
# FUNNEL_GH_BIN convention) — never overridden in production use.
: "${INIT_GH_BIN:=gh}"

usage() {
  cat <<'EOF'
usage: init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
               [--branch NAME] [--base BRANCH] [--remote NAME]
               [--tracker-mode issues|projects] [--board N]
               [--provision-board]
               [--yes-required-check | --no-required-check]
               [--yes-labels | --no-labels]
               [--yes-board | --no-board]
               [--dry-run]
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
init_dir="."
gh_repo_flag=""
no_network=0
init_timeout=10
branch="foundation-init/config"
base=""
remote="origin"
tracker_mode="issues"
board_num=""
provision_board=0
consent_required_check=""
consent_labels=""
consent_board=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) init_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo_flag="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --timeout) init_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --branch) branch="${2:?--branch needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --tracker-mode) tracker_mode="${2:?--tracker-mode needs a value}"; shift 2 ;;
    --board) board_num="${2:?--board needs a value}"; shift 2 ;;
    --provision-board) provision_board=1; shift ;;
    --yes-required-check) consent_required_check=yes; shift ;;
    --no-required-check) consent_required_check=no; shift ;;
    --yes-labels) consent_labels=yes; shift ;;
    --no-labels) consent_labels=no; shift ;;
    --yes-board) consent_board=yes; shift ;;
    --no-board) consent_board=no; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "init.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$tracker_mode" in
  issues|projects) ;;
  *)
    echo "init.sh: --tracker-mode must be 'issues' or 'projects' (got: $tracker_mode)" >&2
    exit 2
    ;;
esac

# --- resolve --dir to a git toplevel (mirrors proposal-pr.sh's own
# resolve_repo_dir, so both scripts agree on what "the repo" means) -------
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
repo_dir="$(abs_dir "$init_dir")" || { echo "init.sh: --dir '$init_dir' does not exist" >&2; exit 1; }
repo_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "init.sh: --dir '$init_dir' is not a git working tree" >&2; exit 1; }
repo_dir="$(abs_dir "$repo_top")"

# Capture the caller's branch BEFORE anything below ever switches it (only
# Step 3's proposal-pr.sh call does that, via `git checkout -B`) — this is
# the "original branch" a partial/failed run needs to restore later (see
# the recovery-marker note ahead of that call, and temperloop#414).  Empty
# when HEAD is detached; the marker is then never written (nothing named
# to restore to).
orig_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

echo "== foundation init =="
echo

# ---------------------------------------------------------------------------
# Step 0 — Epic E soft seam: baseline snapshot, iff the sibling subcommand
# file exists. Never blocks init either way.
#
# --dry-run GATE (temperloop#413): baseline-snapshot.sh is a real writer —
# it appends to .temperloop/baseline.jsonl and self-manages
# .temperloop/.gitignore, both straight to disk, with no proposal-PR/commit
# indirection of its own. A dry run must be genuinely zero-write (bin/
# README.md bills it as "preview first: tree-only, zero API writes"), so
# this step is skipped outright on --dry-run — never invoked, not even in
# some "preview" mode of its own (it has none).
# ---------------------------------------------------------------------------
echo "-- 0. Baseline snapshot (Epic E soft seam) --"
if [ "$dry_run" -eq 1 ]; then
  echo "skipped (--dry-run — tree-only preview, no baseline write)"
elif [ -f "$BASELINE_SNAPSHOT" ]; then
  if (cd "$repo_dir" && bash "$BASELINE_SNAPSHOT"); then
    echo "baseline snapshot written"
  else
    echo "baseline-snapshot.sh exited non-zero — continuing (soft seam, never blocks init)"
  fi
else
  echo "skipped — baseline-snapshot unavailable"
fi
echo

# ---------------------------------------------------------------------------
# Step 1 — the conventions probe (read-only). Forward every flag it
# understands; this script adds no probe behavior of its own.
# ---------------------------------------------------------------------------
echo "-- 1. Conventions probe (read-only) --"
probe_args=(--dir "$repo_dir" --timeout "$init_timeout")
[ -n "$gh_repo_flag" ] && probe_args+=(--gh-repo "$gh_repo_flag")
[ "$no_network" -eq 1 ] && probe_args+=(--no-network)

probe_json="$(bash "$PROBE" "${probe_args[@]}")"
probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "init.sh: conventions-probe failed (exit $probe_rc)" >&2
  exit "$probe_rc"
fi
echo "$probe_json" | jq -c '{schema, repo, ci: .ci.providers}'

probe_schema="$(jq -r '.schema' <<<"$probe_json")"
if [ "$probe_schema" != "1" ]; then
  echo "init.sh: warning — probe schema is $probe_schema; this script understands schema 1 — proceeding best-effort" >&2
fi

gh_repo="$(jq -r '.repo.gh_repo // empty' <<<"$probe_json")"
target_default_branch="$(jq -r '.repo.default_branch // empty' <<<"$probe_json")"
if [ -z "$gh_repo" ]; then
  echo "init.sh: could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote) — the consented-apply step will skip every action" >&2
fi
echo

# ---------------------------------------------------------------------------
# Step 2 — read any existing .temperloop/config: the round-trip half of
# the persisted contract (probe -> config -> init re-reads it). A prior
# run's install manifest is carried forward (merged, never clobbered); an
# unreadable/wrong-schema file is treated as absent, with a warning, so a
# corrupt config can't wedge every future run.
# ---------------------------------------------------------------------------
config_rel=".temperloop/config"
config_path="$repo_dir/$config_rel"
# temperloop#165 rename window (read-old-write-new): a pre-v0.14.0 init
# wrote .foundation/config. When no .temperloop/config exists, READ the
# legacy file so a re-run still merges the old install manifest — but the
# config this run WRITES always lands at .temperloop/config (write-new).
# The legacy read is removed in v0.16.0; `temperloop eject` cleans either
# dir throughout. TEMPERLOOP_LEGACY_WINDOW_CLOSED is a TEST/SIMULATION-ONLY
# seam (never set in production use): =1 simulates the post-v0.16.0
# behavior — a legible refusal naming the migration, never a silent
# fresh-manifest restart on top of forgotten legacy state.
legacy_config_rel=".foundation/config"
read_config_rel="$config_rel"
read_config_path="$config_path"
if [ ! -f "$config_path" ] && [ -f "$repo_dir/$legacy_config_rel" ]; then
  if [ "${TEMPERLOOP_LEGACY_WINDOW_CLOSED:-0}" = "1" ]; then # knob:exempt — test/simulation-only seam
    echo "init.sh: ERROR — found legacy $legacy_config_rel, whose read support was removed in v0.16.0 (the config renamed to .temperloop/config in v0.14.0). Rename the directory (git mv .foundation .temperloop) or run 'temperloop eject' with a pre-v0.16.0 release, then re-run init." >&2
    exit 1
  fi
  echo "init.sh: NOTE — reading legacy $legacy_config_rel (renamed .temperloop/config in v0.14.0; legacy read removed in v0.16.0). This run's config will be written to $config_rel." >&2
  read_config_rel="$legacy_config_rel"
  read_config_path="$repo_dir/$legacy_config_rel"
fi
existing_config=""
existing_installs="[]"
if [ -f "$read_config_path" ]; then
  if existing_config="$(jq -e '.' "$read_config_path" 2>/dev/null)" \
      && [ "$(jq -r '.schema // empty' <<<"$existing_config")" = "1" ]; then
    existing_installs="$(jq -c '.installs // []' <<<"$existing_config")"
    echo "-- Found existing $read_config_rel (schema 1) — merging its install manifest ($(jq 'length' <<<"$existing_installs") entries) --"
  else
    echo "init.sh: warning — existing $read_config_rel is not valid schema-1 JSON; starting a fresh install manifest" >&2
    existing_config=""
  fi
  echo
fi

# --- tracker mode + board number (carried forward unless overridden) -----
if [ -z "$board_num" ] && [ -n "$existing_config" ]; then
  prior_board="$(jq -r '.tracker.board // empty' <<<"$existing_config")"
  [ -n "$prior_board" ] && board_num="$prior_board"
fi
[ -n "$board_num" ] || board_num=1

render_boards_conf_entry() {
  local mode="$1" board="$2" repo="${3:-<owner>/<repo>}"
  case "$mode" in
    issues)
      printf 'board.%s.repo=%s\nboard.%s.backend=issues\n' "$board" "$repo" "$board"
      ;;
    projects)
      printf 'board.%s.repo=%s\n# board.%s.project=<FILL IN — set after the consented board-provisioning apply step creates the project number>\n' "$board" "$repo" "$board"
      ;;
  esac
}
boards_conf_entry="$(render_boards_conf_entry "$tracker_mode" "$board_num" "$gh_repo")"

# ---------------------------------------------------------------------------
# Step 3 — the CONSENTED APPLY STEP: API-state changes only (required
# check, fnd:/funnel labels, opt-in board). Explicit per-action
# confirmation; default is ALWAYS "no" absent an explicit yes (interactive
# prompt or a --yes-<action> flag). --dry-run skips this whole step.
# ---------------------------------------------------------------------------
echo "-- 2. Consented apply step (API-state changes; explicit per-action confirmation) --"

new_installs="[]"
add_install() {
  new_installs="$(jq -c --argjson e "$1" '. + [$e]' <<<"$new_installs")"
}

# _init_confirm <action> <preset> <prompt-text>
#   preset is "yes"/"no"/"" (unset). Prints the decision + why; returns 0
#   for yes, 1 for no. Non-interactive with no preset ALWAYS decides "no"
#   — the safe default (nothing lands without explicit consent).
_init_confirm() {
  local action="$1" preset="$2" prompt="$3"
  case "$preset" in
    yes) echo "$action: yes (--yes-$action)"; return 0 ;;
    no)  echo "$action: no (--no-$action)"; return 1 ;;
  esac
  if [ -t 0 ]; then
    local ans=""
    printf '%s [y/N] ' "$prompt" >&2
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES) echo "$action: yes (operator confirmed)"; return 0 ;;
      *) echo "$action: no (operator declined)"; return 1 ;;
    esac
  fi
  echo "$action: no (skipped — no explicit consent; non-interactive; pass --yes-$action to opt in)"
  return 1
}

if [ "$dry_run" -eq 1 ]; then
  echo "required-check: skipped (--dry-run — tree-only preview, no API writes)"
  echo "labels: skipped (--dry-run)"
  echo "board: skipped (--dry-run)"
elif [ "$no_network" -eq 1 ]; then
  echo "required-check: skipped (--no-network)"
  echo "labels: skipped (--no-network)"
  echo "board: skipped (--no-network)"
elif [ -z "$gh_repo" ]; then
  echo "required-check: skipped (no resolved gh_repo)"
  echo "labels: skipped (no resolved gh_repo)"
  echo "board: skipped (no resolved gh_repo)"
elif ! command -v "$INIT_GH_BIN" >/dev/null 2>&1; then
  echo "required-check: skipped (gh CLI not found on PATH)"
  echo "labels: skipped (gh CLI not found on PATH)"
  echo "board: skipped (gh CLI not found on PATH)"
else
  # --- required status check ------------------------------------------
  if _init_confirm "required-check" "$consent_required_check" \
      "Add 'checks' as a required status check on $gh_repo@${target_default_branch:-<unknown default branch>}?"; then
    if [ -z "$target_default_branch" ]; then
      echo "required-check: FAILED — no default branch resolved"
    elif apply_out="$("$INIT_GH_BIN" api --method PATCH \
        "repos/$gh_repo/branches/$target_default_branch/protection/required_status_checks" \
        -f strict=false -f 'contexts[]=checks' 2>&1)"; then
      echo "required-check: applied (checks required on $target_default_branch)"
      add_install "$(jq -cn --arg repo "$gh_repo" --arg branch "$target_default_branch" --arg name "checks" \
        '{type:"required_check", repo:$repo, branch:$branch, name:$name}')"
    else
      echo "required-check: FAILED — $apply_out"
    fi
  fi

  # --- fnd:/funnel label set -------------------------------------------
  if _init_confirm "labels" "$consent_labels" \
      "Create the fnd:/funnel label set on $gh_repo (fnd:status:backlog/ready/in-progress, needs-clarification, funnel-escalated, decision)?"; then
    existing_label_names="$("$INIT_GH_BIN" label list -R "$gh_repo" --json name -q '.[].name' 2>/dev/null || true)"
    for spec in \
      "fnd:status:backlog|ededed|Tracker status (issues-only backend) — mirrors board.sh Status=Backlog" \
      "fnd:status:ready|ededed|Tracker status (issues-only backend) — mirrors board.sh Status=Ready" \
      "fnd:status:in-progress|ededed|Tracker status (issues-only backend) — mirrors board.sh Status=In Progress" \
      "needs-clarification|fbca04|Open question blocking work — see the needs-clarification convention" \
      "funnel-escalated|d93f0b|A stuck code item awaiting manual merge/close" \
      "decision|c2e0c6|Awaiting an operator decision — see the decision-queue contract"
    do
      label_name="${spec%%|*}"
      rest="${spec#*|}"
      label_color="${rest%%|*}"
      label_desc="${rest#*|}"
      if printf '%s\n' "$existing_label_names" | grep -Fxq "$label_name"; then
        echo "labels: '$label_name' already exists — skipped"
        continue
      fi
      if "$INIT_GH_BIN" label create "$label_name" -R "$gh_repo" \
          --color "$label_color" --description "$label_desc" >/dev/null 2>&1; then
        echo "labels: created '$label_name'"
        add_install "$(jq -cn --arg repo "$gh_repo" --arg name "$label_name" '{type:"label", repo:$repo, name:$name}')"
      else
        echo "labels: FAILED to create '$label_name'"
      fi
    done
  fi

  # --- Projects-v2 board (only ever OFFERED on explicit --provision-board) --
  if [ "$provision_board" -eq 1 ] && [ "$tracker_mode" = "projects" ]; then
    if _init_confirm "board" "$consent_board" \
        "Provision a NEW GitHub Projects-v2 board for $gh_repo (explicit opt-in)?"; then
      board_owner="${gh_repo%%/*}"
      board_repo_name="${gh_repo#*/}"
      if apply_out="$("$INIT_GH_BIN" project create --owner "$board_owner" --title "$board_repo_name board" 2>&1)"; then
        project_url="$(printf '%s\n' "$apply_out" | grep -oE 'https?://[^[:space:]]+' | tail -1)"
        project_number="$(printf '%s\n' "$project_url" | grep -oE '[0-9]+$' || true)"
        echo "board: provisioned project #${project_number:-?} ($project_url)"
        add_install "$(jq -cn --arg owner "$board_owner" --arg url "$project_url" --arg n "${project_number:-}" \
          '{type:"board", owner:$owner, project_number:(if $n == "" then null else ($n|tonumber) end), url:$url}')"
      else
        echo "board: FAILED — $apply_out"
      fi
    fi
  elif [ "$provision_board" -eq 1 ]; then
    echo "board: skipped (--provision-board given but --tracker-mode is 'issues' — nothing to provision)"
  else
    echo "board: skipped (not opted in — pass --provision-board to offer this)"
  fi
fi
echo

# Merge this run's new installs into the carried-forward manifest, deduped
# on the fields that identify an install uniquely.
all_installs="$(jq -c -n --argjson a "$existing_installs" --argjson b "$new_installs" \
  '($a + $b) | unique_by([.type, (.name // ""), (.branch // ""), (.repo // ""), (.url // "")])')"

# ---------------------------------------------------------------------------
# Step 4 — build .temperloop/config content and the tree-only proposal.
# ---------------------------------------------------------------------------
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_config_json() {
  local installs="$1"
  jq -n \
    --argjson schema 1 \
    --arg generated_at "$now_ts" \
    --argjson probe "$probe_json" \
    --arg mode "$tracker_mode" \
    --arg board "$board_num" \
    --arg conf_path "workflows/scripts/board/boards.conf" \
    --arg entry "$boards_conf_entry" \
    --argjson installs "$installs" \
    '{
      schema: $schema,
      generated_at: $generated_at,
      probe: $probe,
      tracker: {
        mode: $mode,
        board: ($board | tonumber? // $board),
        boards_conf_path: $conf_path,
        boards_conf_entry: $entry
      },
      installs: $installs
    }'
}
config_json="$(build_config_json "$all_installs")"

manifest_entries=()
manifest_entries+=("$(jq -cn --arg p "$config_rel" --arg c "$config_json" '{path:$p, content:$c}')")

board_toolkit_dir="$repo_dir/workflows/scripts/board"
if [ -d "$board_toolkit_dir" ]; then
  boards_conf_target="workflows/scripts/board/boards.conf"
  boards_conf_abs="$repo_dir/$boards_conf_target"
  current_conf=""
  [ -f "$boards_conf_abs" ] && current_conf="$(cat "$boards_conf_abs")"
  if printf '%s\n' "$current_conf" | grep -Fq "board.$board_num."; then
    echo "boards.conf: board.$board_num.* already present — leaving $boards_conf_target untouched"
  else
    if [ -n "$current_conf" ]; then
      new_conf="$current_conf"$'\n\n'"$boards_conf_entry"
    else
      new_conf="$boards_conf_entry"
    fi
    manifest_entries+=("$(jq -cn --arg p "$boards_conf_target" --arg c "$new_conf" '{path:$p, content:$c}')")
  fi
else
  echo "boards.conf: workflows/scripts/board/ not present in this repo — rendered entry recorded in $config_rel only:"
  printf '%s\n' "$boards_conf_entry" | sed 's/^/  /'
fi
echo

echo "-- 3. Proposal PR (tree-only; nothing lands without review) --"
title="chore: temperloop init — .temperloop/config"
[ "${#manifest_entries[@]}" -gt 1 ] && title="chore: temperloop init — .temperloop/config + boards.conf"
body="Proposed by \`temperloop init\` (opt-in, reviewable — foundation #765 Epic D).

This PR is TREE-ONLY: it never touches labels, branch protection, or
Projects-v2 board state. Those are applied only via this run's separate
CONSENTED APPLY STEP (explicit per-action confirmation), never through
this PR.

Tracker mode: **$tracker_mode** (default is issues-only; opt into a real
Projects-v2 board with --tracker-mode projects --provision-board)."

if [ "$dry_run" -eq 1 ]; then
  # --dry-run GATE (temperloop#413): genuinely zero-write — compute and
  # print what WOULD be proposed, without ever invoking proposal-pr.sh.
  # proposal-pr.sh's OWN --dry-run mode still performs a REAL local
  # `git checkout -B <branch>` + `git commit` in $repo_dir (its header
  # says so explicitly: "Still a real local git checkout + commit in
  # --repo-dir — nothing remote, nothing on GitHub") — that is exactly
  # the second half of #413's bug report (a dry run left the checkout on
  # foundation-init/config instead of the caller's original branch). So a
  # dry run never calls it at all; this preview is computed locally and
  # read-only, against whatever branch/HEAD the caller already has
  # checked out — it is never switched, and nothing is written to disk.
  echo "dry-run — tree-only preview; zero writes to $repo_dir (no branch switch, no commit, no push, no PR)"
  for entry in "${manifest_entries[@]}"; do
    entry_path="$(jq -r '.path' <<<"$entry")"
    entry_content="$(jq -r '.content' <<<"$entry")"
    entry_abs="$repo_dir/$entry_path"
    if [ ! -e "$entry_abs" ]; then
      echo "  would create: $entry_path"
    elif [ "$(cat "$entry_abs" 2>/dev/null)" = "$entry_content" ]; then
      echo "  unchanged:    $entry_path"
    else
      echo "  would update: $entry_path"
    fi
  done
  outcome="DRY_RUN"
  echo
else
  proposal_args=(open --repo-dir "$repo_dir" --branch "$branch" --title "$title" \
    --body "$body" --files-manifest - --remote "$remote" --force)
  [ -n "$base" ] && proposal_args+=(--base "$base")

  # --- recovery marker (temperloop#414) ------------------------------------
  # proposal-pr.sh's own `git checkout -B "$branch" ...` (inside the call
  # below) is the ONLY branch switch in this whole script — a run that dies
  # anywhere from here on (a killed process, a failed push, a failed `gh pr
  # create`) leaves the checkout sitting on $branch with no further trace of
  # what branch to return to once the process is gone. Record it BEFORE the
  # switch, as untracked (gitignored) recovery state under .temperloop/ — the
  # exact same directory `foundation eject` already owns cleaning up. Cleared
  # right below the instant the switch is known to have succeeded (whatever
  # its outcome — NO_CHANGES/PR_OPENED/EXISTS all mean "this branch is now
  # intentional", not a stray leftover); a run that never reaches that point
  # leaves the marker in place for `foundation eject` (or a later `init` run
  # from the very same branch) to act on. Skipped when already on $branch
  # (nothing to protect against) or HEAD is detached (nothing named to
  # restore to).
  if [ -n "$orig_branch" ] && [ "$orig_branch" != "$branch" ]; then
    mkdir -p "$repo_dir/.temperloop" 2>/dev/null
    jq -cn --arg orig "$orig_branch" --arg prop "$branch" \
      '{original_branch:$orig, proposal_branch:$prop}' \
      > "$repo_dir/.temperloop/.recovery.json" 2>/dev/null || true
    gi_path="$repo_dir/.temperloop/.gitignore"
    if [ -f "$gi_path" ]; then
      grep -Fxq ".recovery.json" "$gi_path" 2>/dev/null || printf '%s\n' ".recovery.json" >> "$gi_path"
    else
      printf '%s\n' ".recovery.json" > "$gi_path"
    fi
  fi

  manifest_json="$(printf '%s\n' "${manifest_entries[@]}" | jq -sc '.')"
  proposal_out="$(printf '%s' "$manifest_json" | bash "$PROPOSAL" "${proposal_args[@]}")"
  proposal_rc=$?
  echo "$proposal_out" | jq '.' 2>/dev/null || echo "$proposal_out"
  if [ "$proposal_rc" -ne 0 ]; then
    echo "init.sh: proposal-pr.sh failed (exit $proposal_rc)" >&2
    exit "$proposal_rc"
  fi
  rm -f "$repo_dir/.temperloop/.recovery.json" 2>/dev/null || true
  outcome="$(jq -r '.outcome // "ERROR"' <<<"$proposal_out" 2>/dev/null || echo ERROR)"
  echo

  # --- bootstrap-ordering second pass: fold THIS run's own PR record into
  # the config that actually lands, once the PR outcome is known (see the
  # header note "BOOTSTRAP ORDERING NOTE"). Skipped for NO_CHANGES — there
  # is no PR to describe. (DRY_RUN can no longer reach this branch at all
  # — see the --dry-run arm above, which returns its own synthetic
  # "DRY_RUN" outcome without ever calling proposal-pr.sh.) --------------
  if [ "$outcome" = "PR_OPENED" ] || [ "$outcome" = "EXISTS" ]; then
    pr_url="$(jq -r '.url // empty' <<<"$proposal_out")"
    pr_number="$(jq -r '.pr_number // empty' <<<"$proposal_out")"
    pr_entry="$(jq -cn --arg branch "$branch" --arg url "$pr_url" --arg n "${pr_number:-}" \
      '{type:"proposal_pr", branch:$branch, pr_number:(if $n == "" then null else ($n|tonumber) end), url:$url}')"
    all_installs2="$(jq -c -n --argjson a "$all_installs" --argjson b "[$pr_entry]" \
      '($a + $b) | unique_by([.type, (.name // ""), (.branch // ""), (.repo // ""), (.url // "")])')"
    config_json2="$(build_config_json "$all_installs2")"
    manifest_entries[0]="$(jq -cn --arg p "$config_rel" --arg c "$config_json2" '{path:$p, content:$c}')"
    manifest_json2="$(printf '%s\n' "${manifest_entries[@]}" | jq -sc '.')"

    echo "-- config self-record pass (folds this run's own PR into $config_rel) --"
    proposal_out2="$(printf '%s' "$manifest_json2" | bash "$PROPOSAL" "${proposal_args[@]}")"
    echo "$proposal_out2" | jq '.' 2>/dev/null || echo "$proposal_out2"
    echo
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "-- 4. Summary --"
echo "tracker mode: $tracker_mode (board $board_num)"
echo "boards.conf entry:"
printf '%s\n' "$boards_conf_entry" | sed 's/^/  /'
echo "config: $config_rel"
echo
echo "foundation init: done"
exit 0
