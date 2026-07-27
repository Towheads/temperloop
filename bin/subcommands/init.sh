#!/usr/bin/env bash
# description: bootstrap .temperloop/config; propose tree changes via PR; offer the pre-designed first epic; print the handoff
#
# init.sh — `temperloop init`: opt-in, reviewable adoption (foundation #765
# Epic D "newcomer experience", item foundation-init / #854).
#
# SCOPE (temperloop#796 — the init scope-down): bootstrap
# `.temperloop/config` (and its proposal PR) -> offer/file the first epic ->
# print the handoff -> STOP. Every *apply* of API STATE this script used to
# perform under its own consent prompt — a required `checks` status check,
# the `fnd:`/pipeline label set, a Projects-v2 board — now belongs to the
# FIRST EPIC's own `## Contract`
# (claude/templates/first-epic-setup.md, ADR 0010), applied later by
# `/assess --epic N` -> `/build`. See "DEPRECATED FLAGS" below: the flags
# that used to gate those applies still parse, and now emit a deprecation
# notice naming where the step went instead of doing anything.
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
#   3. the FIRST-EPIC OFFER, owned by this script — the ONE consented
#      action that remains, and the handoff into the real pipeline. It
#      files an issue (never API state); --dry-run, --no-network, an absent
#      `gh`, or a decline performs zero mutating `gh` calls beyond the
#      decline path's own tracked re-offer pointer.
#
# WHY THE APPLIES MOVED (temperloop#793/#796, ADR 0010 amendment). Two
# reasons, both structural rather than stylistic:
#   - CONGRUENCE. This script's required-check apply was an unconditional
#     `PATCH .../protection/required_status_checks` — it armed a required
#     `checks` context with no regard for whether anything would ever POST
#     that context. The first epic refuses exactly that (ADR 0010
#     § "Structural congruence, not a naming convention"): the required
#     status enters the composed change-set only when its producer was
#     actually configured, so the self-brick failure mode is unreachable
#     rather than merely untested.
#   - REDUNDANCY. The `fnd:`/pipeline label set is created lazily at point
#     of use by the issues-only tracker backend itself
#     (`_board_issues_ensure_label`, workflows/scripts/board/lib/board.sh),
#     memoized per process — pre-creating it here bought nothing and cost
#     six API writes on a first run.
#   - A DANGLING CONTRACT. The board arm rendered
#     `# board.<N>.project=<FILL IN ...>` into boards.conf BEFORE the apply
#     step and never reassigned it, so even a fully-consented, successful
#     provisioning run emitted a placeholder the adapter cannot read.
#     Issues-only is now the sole init-time tracker mode; a Projects-v2
#     board is provisioned by hand (docs/features/install-cli.md
#     § "Manual Projects-v2 recipe").
#
# DEPRECATED FLAGS (retained, each with a NAMED removal window).
# `--yes/--no-required-check`, `--yes/--no-labels`, `--yes/--no-board`,
# `--provision-board`, and `--tracker-mode projects` all still PARSE and all
# still exit 0 — they emit a one-line deprecation notice naming where the
# step went, then are ignored (`--tracker-mode projects` additionally
# coerces to `issues`).
#
# WHY THEY ARE RETAINED. NOT because of the in-repo call sites: those are
# all greppable, and the very change that deprecated these flags rewrote
# .github/workflows/install-tier2.yml to stop passing them — a site this
# repo can edit is not a breakage argument. The real reason is
# VERSIONING.md's **CLI surface** contract row, which names
# `bin/subcommands/*` and "callers of `bin/temperloop` and its
# subcommands": an ADOPTER's own wrapper script, Makefile, or CI job may
# pass any of these, and this script exits 2 on an unknown arg, so a
# removal would hard-fail callers that cannot be enumerated from inside
# this repo. Deprecate-then-remove-on-a-named-release is the contract that
# row implies.
#
# TWO WINDOWS, because these flags do not all belong to one story:
#   1. THE ADR-0004 PROJECTS-ARM REMOVAL — `--provision-board` and
#      `--tracker-mode projects`. Both are Projects-v2 tracker-backend
#      surface, exactly what
#      docs/adr/0004-issues-only-default-backend.md's removal release is
#      scoped to. They ride it.
#   2. THE PRE-SCOPE-DOWN COMPAT WINDOW (v0.20.0) — the three CONSENT
#      pairs `--yes/--no-required-check`, `--yes/--no-labels`, and
#      `--yes/--no-board`. These gated a branch-protection PATCH and a
#      label loop that existed on the ISSUES-ONLY path too, so ADR-0004's
#      Projects-arm removal would never logically cover them; pinning them
#      to it would leave them permanent no-ops wearing a deprecation label,
#      which is a contradiction, not a window. They are removed instead at
#      **v0.20.0**, together with `eject.sh`'s pre-scope-down
#      `required_check`/`label`/`board` read-compat handlers — ONE window,
#      because both halves serve the same cohort: a repo initialised BEFORE
#      the temperloop#796 scope-down, whose `.temperloop/config` may still
#      record that API state and whose wrapper scripts may still pass these
#      flags. Neither half can go while that cohort is still supported, and
#      neither has a reason to outlive it.
#
# The affirmative forms (`--yes-*`, which REQUEST an action that no longer
# happens) still warn-and-continue rather than exiting non-zero. That is a
# deliberate, reversible call, consistent with this script's fail-open
# posture everywhere else: an adopter's unattended job should not start
# failing because of a flag whose action was retired as redundant. Revisit
# it at the v0.20.0 removal, not before.
#
# `temperloop init` is the SOLE WRITER of `.temperloop/config` — no other
# subcommand (this repo's `eject`, once it lands, only READS it) ever
# creates or edits that file. Every side effect this script produces (a
# label, a required-check setting, a proposal branch/PR, a board) is
# recorded in `.temperloop/config`'s `installs` array — the exact set
# `temperloop eject` reverts. Re-running this script MERGES into that
# array rather than clobbering it (see "round-trip" below), and an install
# already recorded from a prior run (or already present on the remote,
# e.g. a label that already existed) is never re-recorded or re-applied.
#
# TRACKER MODE is a THIN RENDER, not a second config store: the functional
# artifact the board adapter (workflows/scripts/board/lib/board.sh) reads
# is `boards.conf`, in its own documented format and discovery path — see
# `workflows/scripts/board/boards.conf.example`. This script only RENDERS
# the `board.<N>.*` lines and, when the target repo has already adopted the
# board toolkit (a `workflows/scripts/board/` dir exists), proposes
# appending them to that repo's `boards.conf` via the SAME proposal-PR
# generator (still tree-only, still reviewable). When the toolkit isn't
# present yet, the rendered entry is only recorded in `.temperloop/config`
# (`tracker.boards_conf_entry`) for the operator to apply by hand later —
# `.temperloop/config` itself is NEVER read by the adapter, so there is no
# risk of two config stores disagreeing. Issues-only
# (`board.<N>.backend=issues`) is now the SOLE init-time tracker mode
# (temperloop#793), and the rendered entry is always COMPLETE — every line
# is a real, adapter-readable assignment, never a commented placeholder the
# adapter's `^board\.N\.axis=` grep would silently fall through.
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
# FIRST-EPIC OFFER (temperloop#610, ADR 0010, item first-epic-offer): since
# the scope-down (temperloop#796) this is the WHOLE of Step 2 — the one
# consented action this script performs, gated behind the same
# gh_repo/gh-binary/dry-run/no-network preconditions the retired
# required-check/labels/board applies used. Consumes the kernel-shipped
# template (claude/templates/first-epic-setup.md) as pure data — this
# script never restates its content, only extracts and substitutes
# <project>.
#   - IDEMPOTENT: probes issue BODIES (never titles) in the adopter's repo
#     for a design-brief marker (accept already happened) or a decline
#     marker (decline already happened + its re-offer pointer was filed)
#     before ever offering — a re-run of this script neither re-files the
#     epic nor re-nags after a decline.
#   - Skip vs. decline are DELIBERATELY DISTINCT outcomes. A non-interactive
#     run (no TTY, or a CI/GITHUB_ACTIONS ambient signal, and no
#     --yes-first-epic/--no-first-epic preset) SKIPS with a plain notice —
#     nobody actually answered, so nothing beyond the notice happens. Only
#     an ACTUAL "no" (typed at a real prompt, or an explicit
#     --no-first-epic) triggers the decline floor below. A decline should
#     leave a durable, tracked trace, which a merely-unattended run has no
#     standing to create on the adopter's behalf.
#   - DECLINE FLOOR (never a vanished gap) — ONE floor, not two, since the
#     scope-down (temperloop#796; ADR 0010's "Decline floors are durable"
#     clause as amended): declining the epic files a durable re-offer
#     pointer (a plain GitHub issue, `fnd:status:backlog` labelled) in the
#     ADOPTER's OWN repo naming exactly what remains unconfigured (branch
#     protection, auto-delete, merge-queue disposition, CI disposition), so
#     the gap stays tracked rather than vanishing. That pointer IS the whole
#     floor. The principles interview no longer runs INLINE here: it is the
#     first epic's own L0 item (`record-principles`, template § Contract),
#     so declining the epic DEFERS the interview rather than running a
#     second, parallel copy of it from this script — and the kernel default
#     (claude/engineering-principles.md) still applies at every review call
#     site's point of use regardless, so declining costs the adopter only
#     the *recorded* choice, never the criteria themselves. The GitHub/CI
#     Phase A/B/C interview likewise only makes sense once the epic exists,
#     and is driven later by /assess --epic N -> /build; this script's job
#     ends at the offer + (on decline) the pointer + the handoff line.
#
# PARTIAL-RUN RECOVERY (temperloop#414): a run that dies anywhere from Step
# 3's proposal-pr.sh call onward (killed process, failed push, failed `gh pr
# create`) leaves the checkout on the proposal branch with no memory of what
# branch it came from. This script writes an untracked `.temperloop/.recovery.json`
# ({"original_branch":...,"proposal_branch":...}) immediately before that
# call and deletes it immediately after the call succeeds (whatever the
# outcome) — so the marker survives on disk exactly when, and only when, a
# run was interrupted mid-switch. `temperloop eject` (kernel/bin/subcommands/
# eject.sh) is the reader: it restores `original_branch` and deletes the
# stray `proposal_branch` when it finds the marker and the checkout is still
# sitting on that branch. A run whose HEAD is detached, or that never
# switches branch (already on it), writes no marker — nothing to restore.
#
# Usage:
#   init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
#           [--branch NAME] [--base BRANCH] [--remote NAME]
#           [--board N]
#           [--yes-first-epic | --no-first-epic]
#           [--dry-run]
#
#   Deprecated, still accepted, ignored (see "DEPRECATED FLAGS" above):
#           [--tracker-mode issues|projects] [--provision-board]
#           [--yes-required-check | --no-required-check]
#           [--yes-labels | --no-labels]
#           [--yes-board | --no-board]
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
#   --board N               Board id the rendered boards.conf
#                          entry uses. Default: carried forward from an
#                          existing .temperloop/config, else 1.
#   --yes-first-epic / --no-first-epic
#                          Pre-answer the first-epic offer instead of an
#                          interactive prompt. A non-interactive run with
#                          NEITHER flag SKIPS the offer entirely (never
#                          asks, never silently declines) — see "FIRST-EPIC
#                          OFFER" above for why a silent skip and an
#                          explicit decline are kept distinct.
#   --dry-run               Forwarded to the proposal generator (local
#                          commit only, nothing pushed, no PR opened) AND
#                          skips the first-epic offer entirely (zero gh
#                          mutation calls of any kind).
#
#   Deprecated (parsed, reported, then ignored — each with a named removal
#   window; see "DEPRECATED FLAGS" above for the windows and why removing
#   one early would break un-greppable adopter callers):
#   --tracker-mode MODE     "issues" (the only mode) or "projects", which
#                          now reports its deprecation and coerces to
#                          "issues". Any other value is still refused with
#                          exit 2. [removed: ADR-0004 Projects-arm release]
#   --provision-board       Legible no-op. A Projects-v2 board is never
#                          provisioned by `init` — see
#                          docs/features/install-cli.md's manual
#                          Projects-v2 recipe for the by-hand path.
#                          [removed: ADR-0004 Projects-arm release]
#   --yes-required-check / --no-required-check
#   --yes-labels / --no-labels
#   --yes-board / --no-board
#                          Legible no-ops. The required `checks` status
#                          check moved to the first epic; the `fnd:`/
#                          pipeline labels are created lazily at point of
#                          use by the issues-only tracker backend; board
#                          provisioning was dropped outright.
#                          [removed: v0.20.0, the pre-scope-down compat
#                          window — see "DEPRECATED FLAGS" above]
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

# Test-double seam (mirrors try.sh's TRY_GH_BIN / pipeline-drive.sh's
# PIPELINE_GH_BIN convention) — never overridden in production use.
: "${INIT_GH_BIN:=gh}"

usage() {
  cat <<'EOF'
usage: init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
               [--branch NAME] [--base BRANCH] [--remote NAME]
               [--board N]
               [--yes-first-epic | --no-first-epic]
               [--dry-run]

deprecated (still accepted, reported, then ignored):
               [--tracker-mode issues|projects] [--provision-board]
               [--yes-required-check | --no-required-check]
               [--yes-labels | --no-labels]
               [--yes-board | --no-board]
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
consent_first_epic=""
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
    --yes-first-epic) consent_first_epic=yes; shift ;;
    --no-first-epic) consent_first_epic=no; shift ;;
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

# ---------------------------------------------------------------------------
# DEPRECATED-FLAG NOTICES (temperloop#796 — the init scope-down).
#
# Every flag below still PARSES (removing one would hard-fail the six
# consumer sites the instant it landed — this script exits 2 on an unknown
# arg — and would make an otherwise-safe release BREAKING). What each one
# now does is: print ONE line naming where the step actually went, then get
# ignored. The notices go to stderr so they can't be mistaken for the
# step's own structured stdout, and they deliberately avoid the
# "skipped — " / "FAILED" wording that .github/workflows/install-tier2.yml
# content-scans for: a deprecated flag is neither a degraded step nor a
# failure, and must not turn the tier-2 round trip red.
# ---------------------------------------------------------------------------
_init_deprecated() {
  # _init_deprecated <flag> <removal-window> <where-it-went>
  #
  # The removal window is named on the line an adopter actually sees, not
  # only in this file's header — a deprecation notice with no stated exit
  # condition is indistinguishable from a permanent no-op.
  echo "init.sh: DEPRECATED — $1 is accepted but ignored (removed in $2): $3" >&2
}

# The two named removal windows — see "DEPRECATED FLAGS" in the header.
deprecated_window_projects="the ADR-0004 Projects-arm removal release"
deprecated_window_consent="v0.20.0, the pre-scope-down compat window"

deprecated_moved_required_check="the required \`checks\` status check is now applied by the first epic (claude/templates/first-epic-setup.md § Contract, item \`github-substrate\`; ADR 0010 § \"Structural congruence\"), which — unlike this step — refuses to arm a required status no producer will ever post. Run it via /assess --epic N -> /build."
deprecated_moved_labels="the \`fnd:\`/pipeline label set is created lazily at point of use by the issues-only tracker backend itself (\`_board_issues_ensure_label\`, workflows/scripts/board/lib/board.sh) — there is nothing left to pre-create."
deprecated_moved_board="board provisioning was dropped from \`init\` outright (temperloop#793); issues-only is the sole init-time tracker mode. Provision a Projects-v2 board by hand — see docs/features/install-cli.md § \"Manual Projects-v2 recipe\"."

[ -n "$consent_required_check" ] \
  && _init_deprecated "--${consent_required_check}-required-check" \
       "$deprecated_window_consent" "$deprecated_moved_required_check"
[ -n "$consent_labels" ] \
  && _init_deprecated "--${consent_labels}-labels" \
       "$deprecated_window_consent" "$deprecated_moved_labels"
[ -n "$consent_board" ] \
  && _init_deprecated "--${consent_board}-board" \
       "$deprecated_window_consent" "$deprecated_moved_board"
[ "$provision_board" -eq 1 ] \
  && _init_deprecated "--provision-board" \
       "$deprecated_window_projects" "$deprecated_moved_board"
if [ "$tracker_mode" = "projects" ]; then
  _init_deprecated "--tracker-mode projects" "$deprecated_window_projects" \
    "coerced to 'issues', the sole init-time tracker mode (temperloop#793). $deprecated_moved_board"
  tracker_mode="issues"
fi

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

echo "== temperloop init =="
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
if [ -z "$gh_repo" ]; then
  echo "init.sh: could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote) — the first-epic offer will skip" >&2
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
# temperloop#165 rename window (read-old-write-new): a pre-v0.15.0 init
# wrote .foundation/config. When no .temperloop/config exists, READ the
# legacy file so a re-run still merges the old install manifest — but the
# config this run WRITES always lands at .temperloop/config (write-new).
# The legacy read is removed in v0.19.0; `temperloop eject` cleans either
# dir throughout. TEMPERLOOP_LEGACY_WINDOW_CLOSED is a TEST/SIMULATION-ONLY
# seam (never set in production use): =1 simulates the post-v0.19.0
# behavior — a legible refusal naming the migration, never a silent
# fresh-manifest restart on top of forgotten legacy state.
legacy_config_rel=".foundation/config"
read_config_rel="$config_rel"
read_config_path="$config_path"
if [ ! -f "$config_path" ] && [ -f "$repo_dir/$legacy_config_rel" ]; then
  if [ "${TEMPERLOOP_LEGACY_WINDOW_CLOSED:-0}" = "1" ]; then # setting:exempt — test/simulation-only seam
    echo "init.sh: ERROR — found legacy $legacy_config_rel, whose read support was removed in v0.19.0 (the config renamed to .temperloop/config in v0.15.0). Rename the directory (git mv .foundation .temperloop) or run 'temperloop eject' with a pre-v0.19.0 release, then re-run init." >&2
    exit 1
  fi
  echo "init.sh: NOTE — reading legacy $legacy_config_rel (renamed .temperloop/config in v0.15.0; legacy read removed in v0.19.0). This run's config will be written to $config_rel." >&2
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

# render_boards_conf_entry <board-id> [owner/repo]
#
# Issues-only is the SOLE init-time tracker mode (temperloop#793), so this
# renders exactly one shape and every line it emits is a REAL, adapter-
# readable assignment. The retired `projects` arm rendered a commented
# `# board.<N>.project=<FILL IN ...>` line here, BEFORE the apply step that
# would have learned the project number, and never reassigned it — so even
# a fully-consented, successful provisioning run shipped a placeholder. And
# because it was a COMMENT, the adapter's `^board\.N\.axis=` grep missed it
# and fell through to its built-in maps rather than failing loudly. There is
# no arm that can emit an incomplete entry any more; test_init.sh pins that
# ("FILL IN" absent from both the config's `tracker.boards_conf_entry` and
# the proposed boards.conf).
render_boards_conf_entry() {
  local board="$1" repo="${2:-<owner>/<repo>}"
  printf 'board.%s.repo=%s\nboard.%s.backend=issues\n' "$board" "$repo" "$board"
}
boards_conf_entry="$(render_boards_conf_entry "$board_num" "$gh_repo")"

# ---------------------------------------------------------------------------
# Step 2 — the FIRST-EPIC OFFER: the ONE consented action `init` still
# performs, and the handoff into the real pipeline (temperloop#796 — the
# init scope-down). It files an ISSUE; it never writes API state. Every
# API-state apply that used to live here (required check, `fnd:` labels,
# Projects-v2 board) is now the first epic's own work — see the "SCOPE" and
# "WHY THE APPLIES MOVED" header notes.
#
# $handoff_next is the single line every arm below sets, printed as the
# closing handoff in the Summary. It is the marker
# .github/workflows/install-tier2.yml greps to prove the live round trip
# reached the handoff rather than degrading somewhere earlier.
# ---------------------------------------------------------------------------
echo "-- 2. First-epic offer (the one consented action; explicit confirmation, default no) --"

handoff_next=""
handoff_prereq=""
handoff_unoffered="run \`temperloop init\` interactively (or pass --yes-first-epic) to file the pre-designed first epic — it is what configures branch protection, head-branch auto-delete, the merge-queue disposition, CI, and your review principles."

if [ "$dry_run" -eq 1 ]; then
  echo "first-epic: skipped (--dry-run — tree-only preview, no API writes)"
  handoff_next="$handoff_unoffered"
elif [ "$no_network" -eq 1 ]; then
  echo "first-epic: skipped (--no-network)"
  handoff_next="$handoff_unoffered"
elif [ -z "$gh_repo" ]; then
  echo "first-epic: skipped (no resolved gh_repo)"
  handoff_next="$handoff_unoffered"
elif ! command -v "$INIT_GH_BIN" >/dev/null 2>&1; then
  echo "first-epic: skipped (gh CLI not found on PATH)"
  handoff_next="$handoff_unoffered"
else
  # --- first epic offer (temperloop#610, ADR 0010) ---------------------
  # See the "FIRST-EPIC OFFER" header comment (top of file) for the full
  # design rationale — skip vs. decline, idempotency probes, the decline
  # floor. This block only ever runs once the surrounding gates above
  # (dry-run/no-network/gh_repo/gh-binary) already passed.
  first_epic_project="$(basename "$gh_repo")"
  first_epic_marker='design-brief: docs/adr/0010-onboarding-as-first-executed-epic.md'
  first_epic_decline_marker="First-epic-decline: $gh_repo"
  first_epic_template="$KERNEL_ROOT/claude/templates/first-epic-setup.md"

  # Mirrors feedback.sh's _feedback_attended: a CI/GITHUB_ACTIONS ambient
  # signal or closed stdin both mean "no live operator to ask" — degrade to
  # a legible skip, never a hang and never a silent "decline".
  _init_first_epic_attended() {
    case "${CI:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # setting:exempt — standard CI-ecosystem ambient signal, not an operator default this repo defines
    case "${GITHUB_ACTIONS:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # setting:exempt — GitHub Actions' own ambient signal, not an operator default this repo defines
    [ -t 0 ] && return 0
    return 1
  }

  # The one line the whole first-epic step exists to produce, once an epic
  # is on the board: the pipeline handoff. Shared by the just-filed and the
  # already-filed arms so a re-run hands off identically to a first run.
  #
  # NAMES ITS PREREQUISITE. `/assess` and `/build` are Claude Code slash
  # commands, and they only reach a machine via `temperloop install`, which
  # symlinks `claude/*` into `~/.claude/`
  # (workflows/scripts/install/links.sh). The adoption ladder
  # (try -> try --demo -> init) otherwise needs no machine-wide setup, so a
  # stranger can very reasonably arrive here with no `~/.claude/commands/`
  # at all — and a handoff naming a command they do not have would defer
  # ALL of this epic's value to a dead pointer, inverting the very
  # first-run experience it exists to fix.
  #
  # The probe is a plain file test against the path links.sh deploys
  # (`~/.claude/commands/assess.md`, resolving through the directory
  # symlink install creates). It only chooses WORDING — both branches name
  # the same next command, and the un-installed branch is phrased so it
  # stays correct even if the probe is wrong (a false negative reads as a
  # redundant "if you haven't", never as a false instruction).
  # The probe only ever ADDS a `prerequisite:` line; it never rewrites the
  # `next step:` line itself. That split is deliberate: `next step: /assess
  # --epic <N>` is a stable marker
  # (.github/workflows/install-tier2.yml greps it, and so does this
  # script's own test suite), so making its wording conditional on a
  # machine-state probe would make the marker conditional too — a probe
  # that silently moved the goalposts for every consumer of that line.
  _init_assess_available() {
    [ -f "${HOME:-}/.claude/commands/assess.md" ]
  }
  # Sets BOTH handoff globals directly rather than echoing for a `$(...)`
  # capture — command substitution runs in a subshell, so a $handoff_prereq
  # assigned in there would be silently discarded.
  _init_set_handoff() {
    handoff_next="$(printf '/assess --epic %s — then /build. That epic is what applies the substrate (branch protection, head-branch auto-delete, merge-queue disposition, CI disposition) and records your review principles.' "$1")"
    if ! _init_assess_available; then
      handoff_prereq="\`/assess\` and \`/build\` are Claude Code slash commands, installed into ~/.claude/ by \`temperloop install\` — run that first. (Nothing else in the try -> try --demo -> init ladder needs it; this step does.)"
    fi
  }

  if [ ! -f "$first_epic_template" ]; then
    echo "first-epic: skipped (template not found at $first_epic_template — broken kernel checkout)"
    handoff_next="$handoff_unoffered"
  else
    # Idempotency probes — search issue BODIES (in:body, never in:title):
    # a prior accept already filed the epic (design-brief marker), or a
    # prior decline already filed the durable re-offer pointer (decline
    # marker). Either hit means: never re-offer.
    first_epic_existing_num="$("$INIT_GH_BIN" api -X GET search/issues \
      -f q="repo:$gh_repo in:body \"$first_epic_marker\"" \
      --jq '.items[0].number // empty' 2>/dev/null || true)"
    first_epic_existing_pointer=""
    if [ -z "$first_epic_existing_num" ]; then
      first_epic_existing_pointer="$("$INIT_GH_BIN" api -X GET search/issues \
        -f q="repo:$gh_repo in:body \"$first_epic_decline_marker\"" \
        --jq '.items[0].number // empty' 2>/dev/null || true)"
    fi

    if [ -n "$first_epic_existing_num" ]; then
      echo "first-epic: already filed as #$first_epic_existing_num — skipping offer (idempotent)"
      _init_set_handoff "$first_epic_existing_num"
    elif [ -n "$first_epic_existing_pointer" ]; then
      echo "first-epic: previously declined — re-offer pointer #$first_epic_existing_pointer already tracks the gap — skipping re-offer"
      handoff_next="the substrate is still unconfigured and tracked by #$first_epic_existing_pointer. Re-run \`temperloop init\` with --yes-first-epic (or open the epic by hand from claude/templates/first-epic-setup.md) when you want it."
    elif [ -z "$consent_first_epic" ] && ! _init_first_epic_attended; then
      echo "first-epic: skipped — no interactive operator detected (no TTY, or an unattended/CI signal is set); point-of-use principle defaults and the managed-merge floor still apply with zero configuration — pass --yes-first-epic/--no-first-epic to decide non-interactively"
      handoff_next="$handoff_unoffered"
    else
      first_epic_decision="$consent_first_epic"
      if [ -z "$first_epic_decision" ]; then
        echo
        echo "temperloop ships a pre-designed first epic: \"Set up $first_epic_project with temperloop\" —"
        echo "it configures engineering-review principles, a GitHub branch/PR/merge substrate, and CI"
        echo "by driving REAL work through this repo's own pipeline (/assess --epic N -> /build), so every"
        echo "future change — yours or an agent's — arrives as a reviewed, gated pull request you can audit."
        echo "See claude/templates/first-epic-setup.md and docs/adr/0010-onboarding-as-first-executed-epic.md."
        echo "Decline, and nothing changes: $first_epic_project is untouched — its branch protection, CI, and"
        echo "merge queue stay unconfigured, though the kernel's review-principle defaults still apply"
        echo "automatically at point of use. We'll file a Backlog item tracking the gap so it's easy to pick"
        echo "up later; you can also re-run this with --yes-first-epic whenever you're ready."
        printf 'Set up %s with temperloop as your first epic? [y/N] ' "$first_epic_project"
        first_epic_ans=""
        read -r first_epic_ans || first_epic_ans=""
        case "$first_epic_ans" in
          y|Y|yes|YES) first_epic_decision=yes ;;
          *)           first_epic_decision=no ;;
        esac
      fi

      if [ "$first_epic_decision" = yes ]; then
        # The epic body is EVERYTHING from the template's own
        # "# Set up <project> with temperloop" heading down — copied
        # verbatim (never restated) after substituting <project>. This is
        # data extraction, not a second copy of the epic's content.
        first_epic_body="$(awk '/^# Set up /{p=1} p' "$first_epic_template" | sed "s/<project>/$first_epic_project/g")"
        if first_epic_url="$("$INIT_GH_BIN" issue create -R "$gh_repo" \
            --title "Set up $first_epic_project with temperloop" \
            --body "$first_epic_body" 2>&1)"; then
          first_epic_num="$(basename "$first_epic_url")"
          echo "first-epic: filed $first_epic_url (#$first_epic_num) — next: /assess --epic $first_epic_num"
          _init_set_handoff "$first_epic_num"
          # NOT recorded into installs[] (temperloop#794): filing this issue
          # is not a revertible API-state side effect the way a label/
          # required-check/board/proposal-branch is — `temperloop eject`
          # must never close or otherwise touch an epic issue an adopter may
          # already be working, so there is no revert action to record. The
          # idempotency probe above (search/issues on $first_epic_marker) is
          # what keeps a re-run from re-offering; installs[] isn't needed for
          # that. (eject.sh's dispatch keeps a read-compat no-op handler for
          # this type in case an older init already wrote one.)
        else
          echo "first-epic: FAILED to file — $first_epic_url"
          handoff_next="$handoff_unoffered"
        fi
      else
        # DECLINE FLOOR — ONE floor, not two (temperloop#796; ADR 0010's
        # "Decline floors are durable" clause as amended). The durable
        # re-offer pointer below IS the whole floor.
        #
        # What used to run here, and why it doesn't any more: an INLINE
        # principles interview, extracted from the template's own "### A1."
        # section and recorded into the knowledge-store priorities note.
        # That was a SECOND, parallel copy of an interview the epic already
        # owns as its L0 item (`record-principles`) — asked by a different
        # actor (this bootstrap script rather than /assess -> /build),
        # writing through a different seam, on the path where the adopter
        # had just said "no". Declining the epic now DEFERS the interview
        # instead of running a shadow of it, and the kernel default
        # (claude/engineering-principles.md) still applies at every review
        # call site's point of use regardless — so declining costs the
        # adopter only the *recorded* choice, never the criteria
        # themselves.
        echo "first-epic: declined — filing a durable re-offer pointer (the whole decline floor; the principles interview is the epic's own L0, deferred rather than run inline)"

        # Durable re-offer pointer — a Backlog item in the ADOPTER's own
        # repo naming exactly what remains unconfigured, so the gap stays
        # tracked rather than vanishing (ADR 0010 § Decline floors).
        "$INIT_GH_BIN" label create "fnd:status:backlog" -R "$gh_repo" \
          --color "ededed" --description "Tracker status (issues-only backend)" >/dev/null 2>&1 || true
        first_epic_pointer_body="temperloop's pre-designed first epic (\"Set up $first_epic_project with temperloop\") was offered by \`temperloop init\` and declined.

Unconfigured substrate this leaves behind:
- Default-branch protection (require-PR, no direct pushes)
- Head-branch auto-delete on merge
- A merge-queue disposition (native queue, or the managed-merge fallback)
- A CI disposition (a scaffolded \`checks\` workflow, or an explicit no-Actions posture)

None of this leaves the repo broken — the kernel's point-of-use principle
defaults and the managed-merge fallback both still work with zero
configuration. Re-run \`temperloop init\` (or open the epic by hand from
claude/templates/first-epic-setup.md) to configure it later.

$first_epic_decline_marker"
        if first_epic_pointer_url="$("$INIT_GH_BIN" issue create -R "$gh_repo" \
            --title "temperloop first-epic setup: still unconfigured" \
            --body "$first_epic_pointer_body" --label "fnd:status:backlog" 2>&1)"; then
          first_epic_pointer_num="$(basename "$first_epic_pointer_url")"
          echo "first-epic: filed durable re-offer pointer $first_epic_pointer_url (#$first_epic_pointer_num)"
          handoff_next="the substrate is still unconfigured and tracked by #$first_epic_pointer_num. Re-run \`temperloop init\` with --yes-first-epic (or open the epic by hand from claude/templates/first-epic-setup.md) when you want it."
          # NOT recorded into installs[] (temperloop#794) — same reasoning
          # as the accept-path issue above: this pointer issue is a durable
          # tracked gap, not a revertible API-state side effect, and eject
          # must never touch it. The idempotency probe above
          # ($first_epic_decline_marker) is what prevents re-offering.
        else
          echo "first-epic: FAILED to file the re-offer pointer — $first_epic_pointer_url"
          handoff_next="$handoff_unoffered"
        fi
      fi
    fi
  fi
fi
echo

# Carry the prior run's install manifest forward, deduped on the fields
# that identify an install uniquely.
#
# Since the scope-down (temperloop#796) this step contributes NOTHING of its
# own: the only entry `init` still mints is the `proposal_pr` one, folded in
# by the self-record second pass below. The carry-forward is deliberately
# kept, and `.temperloop/config`'s schema stays **1**, precisely so an
# EXISTING adopter's recorded `label` / `required_check` / `board` entries
# survive a re-run and stay revertible — `temperloop eject` keeps all four
# handlers, and dropping them from the manifest here would silently strand
# API state it can no longer see.
all_installs="$(jq -c 'unique_by([.type, (.name // ""), (.branch // ""), (.repo // ""), (.url // "")])' \
  <<<"$existing_installs")"

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
Projects-v2 board state. \`temperloop init\` does not apply API state at all
any more (temperloop#796) — branch protection, head-branch auto-delete, the
merge-queue disposition, the required \`checks\` status, and CI are the
first epic's work, applied later with per-write consent via
\`/assess --epic N\` -> \`/build\`.

Tracker mode: **issues-only** (\`board.$board_num.backend=issues\`), the sole
init-time tracker mode. A Projects-v2 board is provisioned by hand — see
\`docs/features/install-cli.md\` § \"Manual Projects-v2 recipe\"."

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
  # exact same directory `temperloop eject` already owns cleaning up. Cleared
  # right below the instant the switch is known to have succeeded (whatever
  # its outcome — NO_CHANGES/PR_OPENED/EXISTS all mean "this branch is now
  # intentional", not a stray leftover); a run that never reaches that point
  # leaves the marker in place for `temperloop eject` (or a later `init` run
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

# --- the handoff (temperloop#796) -----------------------------------------
# `init`'s job ends HERE: bootstrap + propose + offer the first epic + hand
# off. It applies no API state of its own — the epic does, under its own
# per-write consent. `next step:` is the stable marker
# .github/workflows/install-tier2.yml greps to prove the live round trip
# actually reached the handoff.
echo "-- 5. Handoff --"
echo "next step: ${handoff_next:-$handoff_unoffered}"
[ -n "$handoff_prereq" ] && echo "prerequisite: $handoff_prereq"
echo
echo "temperloop init: done"
exit 0
