#!/usr/bin/env bash
#
# env-reconcile.sh — READ-ONLY, FAIL-OPEN environment reconciler (#172).
#
# Enumerates every local checkout / worktree / launchd agent BY ROLE and
# classifies drift against that role's own definition of "clean". This is
# the shared detection substrate for the /tidy environment audit and (agent
# classes) foundation#1089 — it only REPORTS; it never mutates git, launchd,
# or any file outside its own stdout.
#
# ROLES + drift classes:
#
#   cron/kernel checkout   — must be clean-on-main. Drift:
#                              DIRTY        uncommitted changes present
#                              ON_BRANCH    HEAD is not the default branch
#                              BEHIND_MAIN  HEAD is behind the last-fetched
#                                           origin/<default> (checked against
#                                           whatever remote-tracking ref is
#                                           already on disk — this script
#                                           never fetches)
#                            Default checkouts: foundation.cron, the kernel
#                            checkout (temperloop), foundation-kernel (the
#                            pre-rename kernel checkout name some hosts still
#                            carry). Override: ENV_RECONCILE_CRON_CHECKOUTS
#                            (space-separated absolute paths).
#
#   operator/consumer      — may legitimately sit on a feature branch. Drift:
#   checkout                  PARKED_ON_MERGED  on a branch whose PR merged
#                              STALE_UNTRACKED   an untracked file older than
#                                                the staleness horizon
#                              STALE_VENDORED_HOOK:<hook>
#                                                the checkout's VENDORED copy of
#                                                a guard hook
#                                                (.claude/hooks/<hook>) differs
#                                                from this kernel's canonical
#                                                claude/hooks/<hook> — i.e. the
#                                                consumer is running an
#                                                out-of-date guard. See the
#                                                "Vendored-hook drift" block
#                                                below for the comparison
#                                                contract and the remedy.
#                            Default checkouts: foundation, stageFind,
#                            ssmobile, subsetwiki, temperloop (the interactive
#                            operator checkout of the kernel repo — a DIFFERENT
#                            ROLE of the same repo as the cron checkout above at
#                            $HOME/dev/batch/temperloop). Override:
#                            ENV_RECONCILE_OPERATOR_CHECKOUTS.
#
#   worktree <repo>.wt/<slug> — disposable. Drift:
#                            LEAKED_WORKTREE   its build/<slug> branch's PR
#                                              is merged or closed, or the
#                                              directory is ORPHANED (not a
#                                              worktree the parent repo has
#                                              registered)
#                            Scanned beside every cron+operator checkout
#                            above (the deterministic `<repo>.wt/` layout
#                            worktree.sh itself uses).
#
#   launchd agent            each infra/launchd/*.plist declared beside a
#                            checkout above. Drift:
#                              AGENT_UNLOADED  declared AND installed on THIS
#                                              host, but not in `launchctl list`
#                              AGENT_STALE     loaded, but its heartbeat marker
#                                              is older than its cadence (no
#                                              successful run within cadence)
#                              AGENT_CHECKOUT_BEHIND:<dir>
#                                              the plist's declared
#                                              WorkingDirectory resolves to a
#                                              git checkout whose HEAD is
#                                              behind the already-fetched
#                                              origin/<default> (#1624: a
#                                              merged fix can close its issue,
#                                              move its board item to Done,
#                                              and still never reach the
#                                              nightly that actually runs
#                                              from a stale checkout). Reuses
#                                              _behind_origin_default — the
#                                              same default_branch_of ->
#                                              merge-base --is-ancestor
#                                              mechanism BEHIND_MAIN uses
#                                              below, never a fetch. FAIL-OPEN:
#                                              an absent WorkingDirectory key,
#                                              a non-existent path, or a path
#                                              that isn't a git checkout prints
#                                              nothing ("can't verify") rather
#                                              than a crash or a false BEHIND
#                                              claim — see classify_agent_checkout.
#                            Non-drift (informational):
#                              EXPECTED_ELSEWHERE  declared, but this host does
#                                              not own the agent (not installed
#                                              here / not in ENV_RECONCILE_AGENT_HOSTS)
#                                              — the agent host owns it, so its
#                                              not-loaded state is NOT this
#                                              host's drift (#531).
#                            Override: ENV_RECONCILE_LAUNCHD_DIRS
#                            (space-separated dirs to glob *.plist in).
#                            Heartbeat convention (#1173): freshness is judged
#                            from a marker the job writes on SUCCESS, at
#                            $AGENT_HEARTBEAT_DIR/<label>.ran — NEVER from
#                            StandardOutPath's mtime, which launchd touches on
#                            every wake (incl. a wake that aborts having done
#                            nothing). A marker-less agent is reported as
#                            freshness-unknown (nothing emitted), not STALE.
#
# Usage:
#   env-reconcile.sh [--format report|entry]
#
#   --format report   human-readable table + summary (default)
#   --format entry    a `### … Status: open` vault block (modeled on
#                      drain/vault_hygiene_report.sh --format entry) —
#                      emits NOTHING and exits 0 when no drift is found
#
# Library surface (also SOURCEABLE — `source env-reconcile.sh` with no args
# defines the functions below and populates OPERATOR_CHECKOUTS without running
# the reconciler; see the direct-invocation guard ahead of "Main enumeration"):
#   OPERATOR_CHECKOUTS      array — the resolved consumer-checkout registry
#                            (DEFAULT_OPERATOR_CHECKOUTS, or the
#                            ENV_RECONCILE_OPERATOR_CHECKOUTS override) — the
#                            single source of truth for "which checkouts are
#                            kernel consumers", reused (not re-listed) by
#                            /check-in's class-B cross-repo-propagation
#                            discharge (claude/commands/check-in.md).
#   is_kernel_checkout <c>   true iff <c> IS the kernel repo itself (ships
#                            claude/CLAUDE.kernel.md, not claude/CLAUDE.overlay.md
#                            — see the function's own header for the matched site).
#   kernel_pin_tag_of <c>    prints checkout <c>'s installed kernel tag, read
#                            from its own `.kernel-pin` `tag` line; exits 1
#                            (prints nothing) if absent — "not yet reached".
#                            EXCEPTION: when <c> is the kernel repo itself
#                            (is_kernel_checkout), which has no `.kernel-pin`
#                            by construction, the tag is instead the nearest
#                            release tag reachable from <c>'s own HEAD (see
#                            the function's own header, #1333).
#   semver_ge <a> <b>        prints `true`/`false` for a numeric (not
#                            lexical) `vMAJOR.MINOR.PATCH` compare.
#   agent_status_by_label <l> looks up the launchd agent declaring Label <l>
#                            across the resolved LAUNCHD_DIRS registry and
#                            prints classify_agent's verdict for it —
#                            `AGENT_STALE:<l>` / `AGENT_UNLOADED:<l>` / empty
#                            (fresh) — reused (not reinvented) by /check-in's
#                            class-C launchd-sub-case discharge
#                            (claude/commands/check-in.md). Exits 1 (prints
#                            nothing) if no plist declaring <l> is found —
#                            "can't verify", never a crash.
#
# Env overrides (all optional; space-separated path lists unless noted):
#   ENV_RECONCILE_CRON_CHECKOUTS
#   ENV_RECONCILE_OPERATOR_CHECKOUTS
#   ENV_RECONCILE_LAUNCHD_DIRS
#   ENV_RECONCILE_STALE_UNTRACKED_DAYS      (default 7)
#   ENV_RECONCILE_AGENT_HEARTBEAT_DIR       (default $XDG_STATE_HOME/foundation/
#                                            agent-heartbeat — dir of <label>.ran
#                                            markers the jobs write on success)
#   ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S   (default 86400 — used when a
#                                            plist declares no StartInterval)
#   ENV_RECONCILE_AGENT_HOSTS               (host-role override, #531 — space-
#                                            separated host labels that OWN the
#                                            launchd/cron role; compared against
#                                            ${SUBSET_HOST_LABEL:-hostname -s}.
#                                            When set, a host NOT in the list
#                                            reports its agents/cron checkouts as
#                                            EXPECTED_ELSEWHERE. When UNSET, the
#                                            install-marker auto-detect below is
#                                            used instead — no config needed.)
#   ENV_RECONCILE_AGENT_INSTALL_DIR         (default ~/Library/LaunchAgents — the
#                                            launchd user-agent install dir whose
#                                            plists mark which agents THIS host
#                                            actually runs, #531)
#   ENV_RECONCILE_CANONICAL_HOOK_DIR        (default <this repo>/claude/hooks —
#                                            the canonical hook source the
#                                            vendored copies are compared against)
#   ENV_RECONCILE_VENDORED_HOOKS            (default build-worktree-guard.sh —
#                                            space-separated hook basenames to
#                                            compare)
#
# ── Vendored-hook drift (STALE_VENDORED_HOOK, foundation#1353 / F#932) ────────
# A guard hook is the source of truth HERE (claude/hooks/) and is push-synced
# into each consumer repo at .claude/hooks/<hook>, where it is registered in
# that repo's project-level .claude/settings.json. Nothing reported when a
# consumer's copy fell behind — so a consumer could keep running a guard whose
# protections the kernel has since widened, silently. That is exactly the F#932
# shape: the write-jail's matcher was `Edit|Write|MultiEdit` only, worker Bash
# was un-jailed, and a worker's `rm -rf "$(dirname "$(pwd)")"` deleted every
# checkout and the local knowledge store. The kernel grew a Bash arm; the
# consumers kept the pre-Bash-arm copy and nothing said so.
#
# Comparison contract:
#   - CONTENT comparison, never a version stamp. A stamp needs kernel-side
#     coordination to bump and can itself go stale (it says what the syncer
#     BELIEVED, not what the file IS); the bytes cannot lie. This is
#     deliberately a different mechanism from board-sync-drift-check.sh's
#     single-manifest SHA — that check runs inside a consumer's own CI against
#     an explicit expected SHA; this one runs on the operator's host with no
#     agreed reference but the canonical file itself.
#   - The sync stamps a provenance PREAMBLE onto its output: after the shebang
#     it injects THREE lines — the "# GENERATED by foundation '<cmd>' …" banner,
#     the "# Source of truth: …" note, and a bare "#" separator. All three are
#     EXCLUDED from the comparison (_hook_body is the injector's exact inverse)
#     — they are present by construction in every synced copy and absent from
#     the canonical file, so counting even ONE of them would make every
#     correctly-synced consumer permanently and unclearably "drifted".
#     ⚠️ The injector lives in the consumer-side fleet Makefile (foundation
#     Makefile:458) and this strip lives here in the kernel, with NOTHING
#     mechanically linking them — see _hook_body's own note; the in-sync test
#     fixture is deliberately built with the real injector so a shape change
#     fails the suite rather than silently false-alarming production.
#   - The remedy is read from the copy's OWN banner (which names the exact sync
#     command that produced it), VALIDATED to a bare `make <target>` shape, and
#     falls back to the generic engine invocation otherwise. No mapping table to
#     keep in sync with the fleet Makefile's wrappers. The named target lives in
#     that fleet repo, NOT in this kernel repo, so the remedy is rendered with
#     its run location.
#   - Which hooks are compared is ENV_RECONCILE_VENDORED_HOOKS. Renaming the
#     canonical hook without updating that list turns this check into a silent
#     no-op. That is the fail-open invariant working as specified (an
#     unresolvable reference must never manufacture drift), noted here so the
#     trade-off is visible rather than surprising.
#
# DETECTION ONLY. This class makes the staleness visible; auto-syncing a
# consumer on kernel merge (foundation#694) is the durable fix and is NOT
# duplicated here. Reporting — never healing — is also what the "aggressive
# in-lane, report cross-lane" environment-hygiene policy requires: a consumer
# checkout is a foreign lane, so its drift is surfaced for /check-in to dispose,
# never silently rewritten from under whichever session owns it.
#
# Deliberately NOT a `make doctor` check: doctor runs at every session start and
# its pinned contract is "doctor non-zero → run `make install` to heal". A stale
# hook in a FOREIGN checkout is not healable by `make install` (that would be a
# foreign-tree write), so a doctor class here would pin doctor non-zero forever,
# fire a futile `make install` every session, and bury doctor's real
# MISSING/DANGLING signal.
#
# READ-ONLY / FAIL-OPEN contract: this script never runs `git fetch`, never
# writes a file, never calls `launchctl load/unload`, never invokes `gh` in
# any but a read (`pr view`) mode. A missing tool (gh, launchctl), a
# non-existent checkout, or a malformed plist is skipped/degraded rather than
# aborting — the script always exits 0 except on a genuine usage error (2).
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) with BSD-vs-
# GNU stat fallbacks, so it runs on the macOS dev shell as well as Linux CI.
# It is primarily a DIRECTLY-INVOKED script (env-hygiene-report.sh + /tidy
# call it by bare path) — tracked 100755, like its sourced-only sibling
# lib/merged-detect.sh is NOT — but it is also safely sourceable for its
# library surface above (a `source`'d run's arg-parse loop simply sees an
# empty "$@" and its main-enumeration body is skipped by the direct-invocation
# guard, so sourcing never runs the reconciler or trips one of its `exit`s).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Override seams (tests redefine these — same convention as
#    merged-detect.sh's _merged_detect_gh / gate.sh's _gate_gh) ──────────────
_env_reconcile_launchctl() { launchctl "$@"; }

# ── Source the shared merged-detection helper ────────────────────────────────
# shellcheck source=lib/merged-detect.sh
source "$SCRIPT_DIR/lib/merged-detect.sh" 2>/dev/null || true
if ! command -v merged_detect_is_merged >/dev/null 2>&1; then
  # Fail-open stand-in if the sibling lib is somehow missing — never treat
  # anything as "merged" on uncertain grounds (mirrors the lib's own default).
  merged_detect_is_merged() { printf 'false\n'; return 0; }
fi
# _merged_detect_gh is defined by the sourced lib above (or, if the source
# failed, is simply undefined — _pr_state_of below tolerates that via `|| true`).

# ── Arg parse ─────────────────────────────────────────────────────────────────
FORMAT="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in report|entry) ;; *) echo "unknown --format: $FORMAT (report|entry)" >&2; exit 2 ;; esac

# ── Tunables (env-overridable) ────────────────────────────────────────────────
STALE_UNTRACKED_DAYS="${ENV_RECONCILE_STALE_UNTRACKED_DAYS:-7}"
AGENT_DEFAULT_CADENCE_S="${ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S:-86400}"
# Heartbeat markers: the reliable freshness signal (#1173). A launchd job touches
# $AGENT_HEARTBEAT_DIR/<label>.ran on SUCCESSFUL completion; env-reconcile reads
# the marker's mtime, never StandardOutPath (which launchd touches on every wake).
AGENT_HEARTBEAT_DIR="${ENV_RECONCILE_AGENT_HEARTBEAT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/agent-heartbeat}"

# Vendored-hook drift (STALE_VENDORED_HOOK). The canonical source is THIS repo's
# own claude/hooks/ — resolved from SCRIPT_DIR (workflows/scripts/build) up three
# levels. That holds both in a bare kernel checkout and inside a consumer's
# vendored `kernel/` subtree, since either way the canonical hook sits beside the
# reconciler running the comparison. Empty (unresolvable) = the comparison is
# skipped entirely: fail-open, never a false alarm from a missing reference.
_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd -P)" || _REPO_ROOT=""
DEFAULT_CANONICAL_HOOK_DIR=""
[ -n "$_REPO_ROOT" ] && DEFAULT_CANONICAL_HOOK_DIR="$_REPO_ROOT/claude/hooks"
CANONICAL_HOOK_DIR="${ENV_RECONCILE_CANONICAL_HOOK_DIR:-$DEFAULT_CANONICAL_HOOK_DIR}"
read -r -a VENDORED_HOOKS <<<"${ENV_RECONCILE_VENDORED_HOOKS:-build-worktree-guard.sh}"

# ── Host-role ownership (#531) ────────────────────────────────────────────────
# The launchd-agent and cron-checkout roles are owned by ONE host (the agent host),
# not every machine that carries this checkout. A laptop that never installed
# the plists and never held the cron checkouts must NOT report the agent host's agents
# as AGENT_UNLOADED nor the agent host's cron checkouts as ABSENT — that drift belongs
# to the owning host, and flagging it everywhere is the #531 false-positive.
#
# Ownership resolves through two seams, cheapest-first, both READ-ONLY:
#   1. Explicit host list — ENV_RECONCILE_AGENT_HOSTS (space-separated host
#      labels, matched against this host's ${SUBSET_HOST_LABEL:-hostname -s}).
#      When set, THIS host owns the role iff it is in the list; every other host
#      classifies the agents/cron checkouts as EXPECTED_ELSEWHERE (not drift).
#   2. Install-marker auto-detect (default, zero-config) — a launchd USER agent
#      is "installed" on a host only when its plist lives in the launchd agents
#      directory ($AGENT_INSTALL_DIR, default ~/Library/LaunchAgents). If a
#      declared plist is NOT installed here, this host does not run that agent →
#      EXPECTED_ELSEWHERE; if it IS installed but not loaded → genuine
#      AGENT_UNLOADED. The install directory being empty of the declared agents
#      is exactly the laptop's self-describing "not my role" signal.
RECONCILE_HOST="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)}"
AGENT_INSTALL_DIR="${ENV_RECONCILE_AGENT_INSTALL_DIR:-$HOME/Library/LaunchAgents}"
read -r -a AGENT_HOSTS <<<"${ENV_RECONCILE_AGENT_HOSTS:-}"

DEFAULT_CRON_CHECKOUTS="$HOME/dev/foundation.cron $HOME/dev/batch/temperloop $HOME/dev/foundation-kernel"
# Note: $HOME/dev/batch/temperloop (cron, above) and $HOME/dev/temperloop
# (operator, here) are two DIFFERENT ROLES of the SAME repo — the cron/kernel
# checkout is clean-on-main, the interactive operator checkout legitimately
# sits on feature branches and owns the temperloop.wt/* worktrees. Both must be
# registered so each is classified against its own baseline.
DEFAULT_OPERATOR_CHECKOUTS="$HOME/dev/foundation $HOME/dev/stageFind $HOME/dev/ssmobile $HOME/dev/subsetwiki $HOME/dev/temperloop"

read -r -a CRON_CHECKOUTS <<<"${ENV_RECONCILE_CRON_CHECKOUTS:-$DEFAULT_CRON_CHECKOUTS}"
read -r -a OPERATOR_CHECKOUTS <<<"${ENV_RECONCILE_OPERATOR_CHECKOUTS:-$DEFAULT_OPERATOR_CHECKOUTS}"

# bash-3.2 note: `"${arr[@]}"` on a DECLARED-BUT-EMPTY array is an "unbound
# variable" error under `set -u` on bash < 4.4 (macOS ships 3.2) — every array
# expansion below is guarded by an index-based loop over `${#arr[@]}` (safe
# even when 0) rather than a bare `for x in "${arr[@]}"`.
LAUNCHD_DIRS=()
if [ -n "${ENV_RECONCILE_LAUNCHD_DIRS:-}" ]; then
  read -r -a LAUNCHD_DIRS <<<"$ENV_RECONCILE_LAUNCHD_DIRS"
else
  _i=0
  while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
    _c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    [ -d "$_c/infra/launchd" ] && LAUNCHD_DIRS+=("$_c/infra/launchd")
  done
  _i=0
  while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
    _c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    [ -d "$_c/infra/launchd" ] && LAUNCHD_DIRS+=("$_c/infra/launchd")
  done
fi

# ── Portable stat/date helpers (mirrors vault_hygiene_report.sh) ─────────────
# Portable mtime-as-epoch. GNU-first, then BSD — each branch emits ONLY on
# success (guarded by capture + non-empty check), because GNU `stat -f %m`
# mis-parses as filesystem mode and leaks a multi-line "File: …" blob to stdout
# while exiting non-zero, which a bare `A || B` would concatenate into the result
# (breaking the arithmetic that consumes it under `set -u`).
file_mtime() {
  local m
  if m="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  if m="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  echo 0
}
now_epoch() { date +%s; }

# ── is_kernel_checkout <checkout> ─────────────────────────────────────────────
# True iff <checkout> IS the kernel repo itself, rather than a checkout that
# merely vendors the kernel in as a consumer. Same detection convention
# validate-capture-backstop.sh already uses for its own KERNEL_ONLY_MD case
# (workflows/scripts/validate-capture-backstop.sh:68-70): a bare kernel
# checkout ships `claude/CLAUDE.kernel.md` but never `claude/CLAUDE.overlay.md`
# (a composed/overlay consumer checkout carries both — the overlay half is
# personal/org content the kernel repo itself never ships). Matched here
# rather than reinvented so the two checks agree on what "is the kernel repo"
# means.
is_kernel_checkout() {
  local checkout="$1"
  [ -f "$checkout/claude/CLAUDE.kernel.md" ] && [ ! -f "$checkout/claude/CLAUDE.overlay.md" ]
}

# ── kernel_pin_tag_of <checkout> ──────────────────────────────────────────────
# Reads the installed kernel tag straight from a consumer checkout's own
# `.kernel-pin` file (atomically written by `scripts/update-kernel.sh`; NOT a
# new stamp — this is the /check-in class-B discharge's only source of truth
# for "what kernel tag is this consumer running"). Prints the tag (e.g.
# `v0.12.1`) and exits 0 on success; prints nothing and exits 1 when the
# checkout or its `.kernel-pin` is absent or has no `tag` line — the caller
# treats that as "not yet reached", never a crash (a straggler/never-updated
# consumer keeps a class-B record open, it doesn't abort the discharge pass).
#
# EXCEPTION — the checkout IS the kernel repo (is_kernel_checkout above).
# `.kernel-pin` is the vendored-subtree identity carrier a CONSUMER writes;
# the kernel repo is never its own consumer, so it can never have one BY
# CONSTRUCTION — treating that absence as "not yet reached" would make any
# `all-consumers` class-B record permanently undischargeable the moment the
# kernel checkout is in scope (temperloop#1333: exactly the failure
# `719-pointer-collapse` / `719-apply-approved-deletions` /
# `719-terminology-consolidation` hit). Instead resolve "reached" from the
# checkout's OWN history: the nearest release tag that is an ancestor of its
# HEAD is the version this checkout has itself reached — the same tag a
# consumer would record in `.kernel-pin` if it updated right now. A checkout
# that hasn't fetched/merged far enough correctly resolves to an OLDER tag (or
# none), so a stale kernel checkout still reads "not yet reached" — this stays
# fail-open, never a blanket "always discharged".
kernel_pin_tag_of() {
  local checkout="$1" pin tag
  if is_kernel_checkout "$checkout"; then
    tag="$(git -C "$checkout" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)" || return 1
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
    return 0
  fi
  pin="$checkout/.kernel-pin"
  [ -f "$pin" ] || return 1
  tag="$(awk '$1=="tag"{print $2; exit}' "$pin" 2>/dev/null)"
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
  return 0
}

# ── semver_ge <a> <b> ──────────────────────────────────────────────────────────
# bash-3.2-safe semver `a >= b` compare for the `vMAJOR.MINOR.PATCH` tag shape
# (a leading `v` is optional on either side; a missing component defaults to
# 0). Prints `true` or `false` on stdout and always exits 0 — this is a pure
# string-in/string-out helper, never a pass/fail exit code, so callers test
# its printed value rather than `$?`. NUMERIC comparison, not lexical: lexical
# order would wrongly rank "0.9.0" above "0.12.1" (`9` > `1` as the first
# differing character); semver_ge compares each dotted component as an
# integer instead. (BSD `sort -V` on macOS also orders these correctly and is
# a fine ad-hoc sanity check — `printf 'v0.9.0\nv0.12.1\n' | sort -V` — but
# this function is used directly rather than shelling out to `sort` so the
# compare stays a single in-process call.)
semver_ge() {
  local a="${1#v}" b="${2#v}" a_maj a_min a_pat b_maj b_min b_pat
  IFS='.' read -r a_maj a_min a_pat <<<"$a"
  IFS='.' read -r b_maj b_min b_pat <<<"$b"
  a_maj="${a_maj%%[^0-9]*}"; a_min="${a_min%%[^0-9]*}"; a_pat="${a_pat%%[^0-9]*}"
  b_maj="${b_maj%%[^0-9]*}"; b_min="${b_min%%[^0-9]*}"; b_pat="${b_pat%%[^0-9]*}"
  a_maj="${a_maj:-0}"; a_min="${a_min:-0}"; a_pat="${a_pat:-0}"
  b_maj="${b_maj:-0}"; b_min="${b_min:-0}"; b_pat="${b_pat:-0}"
  if [ "$a_maj" -gt "$b_maj" ]; then printf 'true\n'; return 0; fi
  if [ "$a_maj" -lt "$b_maj" ]; then printf 'false\n'; return 0; fi
  if [ "$a_min" -gt "$b_min" ]; then printf 'true\n'; return 0; fi
  if [ "$a_min" -lt "$b_min" ]; then printf 'false\n'; return 0; fi
  if [ "$a_pat" -ge "$b_pat" ]; then printf 'true\n'; return 0; fi
  printf 'false\n'
  return 0
}

# ── Findings accumulator ──────────────────────────────────────────────────────
alarms=0
FINDINGS=""
add() { FINDINGS="${FINDINGS}$1"$'\n'; [ "${2:-}" = "drift" ] && alarms=$((alarms + 1)); }

is_git_repo() { git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; }
current_branch_of() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null; }

# Mirrors worktree.sh's default_branch() — READ-ONLY, no fetch: resolves from
# whatever origin/HEAD or main/master ref is already on disk.
default_branch_of() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# PR state via the same gh override seam merged-detect.sh sources in
# (_merged_detect_gh) — read-only (`pr view`), fail-open to UNKNOWN on any
# gh error (not installed / offline / rate-limited).
_pr_state_of() {
  local repo="$1" branch="$2" state
  if ! command -v _merged_detect_gh >/dev/null 2>&1; then
    printf 'UNKNOWN\n'
    return 0
  fi
  state="$(cd "$repo" && _merged_detect_gh pr view "$branch" --json state --jq .state 2>/dev/null)" || {
    printf 'UNKNOWN\n'
    return 0
  }
  case "$state" in
    MERGED | OPEN | CLOSED) printf '%s\n' "$state" ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}

# ── _behind_origin_default <repo> ─────────────────────────────────────────────
# Prints 'true' when <repo>'s current HEAD is checked out on its default
# branch AND is a strict ancestor of the already-fetched origin/<default> —
# i.e. genuinely behind. Prints 'false' for every other case, INCLUDING every
# can't-tell case (not a git repo, no default branch resolvable, no
# origin/<default> ref on disk yet, detached HEAD, HEAD on a non-default
# branch): the caller treats 'false' as "no evidence of drift", exactly the
# fail-open posture this block had inline (in classify_cron_checkout) before
# it was extracted here so classify_agent_checkout could reuse the identical
# mechanism rather than reimplementing it (#1624). NEVER fetches — compares
# only against whatever remote-tracking ref is already on disk. Always exits
# 0 — a print-only helper like semver_ge above; callers test the printed
# value, never $?.
_behind_origin_default() {
  local repo="$1" branch default head origin_head
  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || { printf 'false\n'; return 0; }
  if [ -z "$branch" ] || [ "$branch" != "$default" ]; then
    printf 'false\n'
    return 0
  fi
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { printf 'false\n'; return 0; }
  git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$default" || { printf 'false\n'; return 0; }
  origin_head="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" || origin_head=""
  if [ -n "$origin_head" ] && [ "$head" != "$origin_head" ] \
    && git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# ── classify_cron_checkout <repo> ─────────────────────────────────────────────
# Prints zero or more space-separated class tokens (empty = OK).
classify_cron_checkout() {
  local repo="$1" classes="" branch default
  [ -d "$repo" ] || { printf 'ABSENT'; return 0; }
  is_git_repo "$repo" || { printf 'NOT_A_REPO'; return 0; }

  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || default="main"

  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    classes="${classes}DIRTY "
  fi

  if [ -z "$branch" ]; then
    classes="${classes}ON_BRANCH:(detached) "
  elif [ "$branch" != "$default" ]; then
    classes="${classes}ON_BRANCH:${branch} "
  elif [ "$(_behind_origin_default "$repo")" = "true" ]; then
    classes="${classes}BEHIND_MAIN "
  fi

  printf '%s' "$classes"
}

# ── Vendored-hook drift helpers (STALE_VENDORED_HOOK) ─────────────────────────
# _hook_body <file> — the file's content with the sync's provenance BANNER
# removed, so a synced copy and its canonical source compare equal when only the
# banner differs.
#
# EXACT INVERSE OF THE INJECTOR. The hook-sync's recipe is
#   awk 'NR==1{print; print b; print s; print "#"; next} {print}'
# i.e. after the shebang it inserts exactly THREE lines: the "GENERATED by …
# DO NOT EDIT HERE" banner, the "Source of truth: …" note, and a bare `#`
# separator. So this strips exactly lines 2-4, and ONLY when line 2 is the
# banner — which makes it a no-op on the canonical file (no banner at line 2),
# keeping the two streams symmetric.
#
# The bare `#` is the load-bearing third line: dropping only the two commented
# lines leaves it behind in every synced copy and absent from canonical, so the
# streams could never compare equal and EVERY correctly-synced consumer would
# report permanent, unclearable drift (following the remedy re-runs the injector
# and reproduces the identical file). That self-perpetuating alarm is exactly the
# fatigue shape that buries the real signal this class exists to raise.
#
# ⚠️ CROSS-REPO COUPLING, NOT MECHANICALLY LINKED: this strip lives in the kernel
# while the injector lives in the CONSUMER-side fleet Makefile's `sync-hooks`
# recipe (foundation Makefile:458, the `inject()` awk one-liner above). Nothing
# checks the two stay inverses — if the injected preamble's shape ever changes,
# this function must change with it, and the in-sync fixture in
# tests/test_env_reconcile.sh (built with the REAL injector, deliberately) is
# what catches the mismatch.
#
# Positional, not pattern-global: a body line deeper in the file that happens to
# read "Source of truth:" is content, not banner, and is never silently dropped.
# Nothing else is normalised — any other byte difference IS drift.
_hook_body() {
  awk '
    NR==1 { print; next }
    NR==2 && /^# *GENERATED by / { stripped=1; next }
    stripped && (NR==3 || NR==4) { next }
    { print }
  ' "$1" 2>/dev/null
}

# _vendored_hook_sync_cmd <repo> <hook> — the exact command that re-syncs <hook>
# into <repo>. Read from the vendored copy's OWN banner, which names the make
# target that produced it (`# GENERATED by foundation 'make sync-<x>-hooks' …`);
# falls back to the generic sync engine with an explicit TARGET_REPO when the
# copy carries no banner. Self-describing — no repo→target mapping table here
# that could itself drift from the fleet Makefile's wrappers.
#
# THE CAPTURE IS UNTRUSTED INPUT AND IS VALIDATED BEFORE USE. Its source is the
# very file this check exists because it cannot be assumed to match canonical —
# a garbled, truncated, or hand-edited banner is the realistic case. This script
# never executes the string, but `--format entry` is appended to the hygiene
# report that /check-in READS AND DISPOSES, so an unvalidated capture hands an
# agent an authoritative-looking command line sourced from a suspect file (a
# planted banner reading `make sync-x-hooks; curl … | sh; rm -rf …` otherwise
# renders verbatim). So the capture is accepted ONLY in the narrow shape a
# legitimate SYNC_LABEL produces — `make <target>`, a single bare target of
# word/dot/dash characters — and anything else falls back to the generic engine
# invocation. That keeps the self-describing property for real banners while
# making the surface un-injectable.
#
# The emitted command is a FLEET-Makefile target (`sync-<x>-hooks` lives in the
# consumer-side fleet repo, not in this kernel repo, which has no such target),
# so callers render it with its run location — see the emit site.
_vendored_hook_sync_cmd() {
  local repo="$1" hook="$2" cmd
  cmd="$(sed -n "s/^#[[:space:]]*GENERATED by [A-Za-z0-9_-]* '\([^']*\)'.*/\1/p" \
    "$repo/.claude/hooks/$hook" 2>/dev/null | head -1)"
  case "$cmd" in
    "make "[A-Za-z0-9_]*)
      # Re-check the tail against the allowed charset: no whitespace, no shell
      # metacharacters, no second word — a bare `make <target>` and nothing else.
      case "${cmd#make }" in
        *[!A-Za-z0-9_.-]*) cmd="" ;;
      esac
      ;;
    *) cmd="" ;;
  esac
  if [ -n "$cmd" ]; then
    printf '%s\n' "$cmd"
  else
    printf 'make sync-hooks TARGET_REPO=%s\n' "$repo"
  fi
}

# _stale_vendored_hooks <repo> — prints a space-terminated
# `STALE_VENDORED_HOOK:<hook>` token per vendored hook whose banner-stripped body
# differs from canonical. FAIL-OPEN and SILENT on every uncertain case: no
# resolvable canonical dir, no `cmp`, a canonical file that is missing/unreadable,
# or a consumer that simply vendors no copy of the hook — each is skipped without
# a token and without a message. Only a readable-copy-vs-readable-canonical
# mismatch raises the class.
_stale_vendored_hooks() {
  local repo="$1" out="" h canon vend _i=0
  [ -n "$CANONICAL_HOOK_DIR" ] || { printf ''; return 0; }
  command -v cmp >/dev/null 2>&1 || { printf ''; return 0; }
  while [ "$_i" -lt "${#VENDORED_HOOKS[@]}" ]; do
    h="${VENDORED_HOOKS[$_i]}"; _i=$((_i + 1))
    [ -n "$h" ] || continue
    canon="$CANONICAL_HOOK_DIR/$h"
    vend="$repo/.claude/hooks/$h"
    [ -r "$canon" ] || continue   # no reference to compare against — skip
    [ -r "$vend" ] || continue    # consumer vendors no copy — not this class
    if ! cmp -s <(_hook_body "$canon") <(_hook_body "$vend"); then
      out="${out}STALE_VENDORED_HOOK:${h} "
    fi
  done
  printf '%s' "$out"
}

# ── classify_operator_checkout <repo> ─────────────────────────────────────────
classify_operator_checkout() {
  local repo="$1" classes="" branch default merged now f m age_days
  [ -d "$repo" ] || { printf 'ABSENT'; return 0; }
  is_git_repo "$repo" || { printf 'NOT_A_REPO'; return 0; }

  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || default="main"

  if [ -n "$branch" ] && [ "$branch" != "$default" ]; then
    merged="$(merged_detect_is_merged "$repo" "$branch" "$default" 2>/dev/null)" || merged="false"
    [ "$merged" = "true" ] && classes="${classes}PARKED_ON_MERGED:${branch} "
  fi

  now="$(now_epoch)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(file_mtime "$repo/$f")"
    age_days=$(( (now - m) / 86400 ))
    if [ "$age_days" -gt "$STALE_UNTRACKED_DAYS" ]; then
      classes="${classes}STALE_UNTRACKED:${f} "
    fi
  done < <(git -C "$repo" status --porcelain 2>/dev/null | awk '/^\?\?/{ sub(/^\?\? /,""); print }')

  # An out-of-date VENDORED guard hook — the consumer is running protections the
  # kernel has since widened (see the "Vendored-hook drift" block in the header).
  classes="${classes}$(_stale_vendored_hooks "$repo")"

  printf '%s' "$classes"
}

# ── classify_worktree <repo> <wt_dir> ─────────────────────────────────────────
# <repo> is the PARENT checkout root (without .wt); <wt_dir> is the
# <repo>.wt/<slug> directory being examined.
classify_worktree() {
  local repo="$1" wt="$2" slug branch wt_abs merged state
  slug="$(basename "$wt")"
  branch="build/${slug}"

  wt_abs="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_abs="$wt"

  if ! git -C "$repo" worktree list --porcelain 2>/dev/null | grep -xF "worktree $wt_abs" >/dev/null; then
    printf 'LEAKED_WORKTREE:ORPHANED:%s' "$slug"
    return 0
  fi

  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf 'LEAKED_WORKTREE:BRANCH_GONE:%s' "$slug"
    return 0
  fi

  merged="$(merged_detect_is_merged "$repo" "$branch" 2>/dev/null)" || merged="false"
  if [ "$merged" = "true" ]; then
    printf 'LEAKED_WORKTREE:MERGED:%s' "$slug"
    return 0
  fi

  state="$(_pr_state_of "$repo" "$branch")"
  if [ "$state" = "CLOSED" ]; then
    printf 'LEAKED_WORKTREE:CLOSED:%s' "$slug"
    return 0
  fi

  printf ''
}

# ── naive dependency-free plist XML key extractor ────────────────────────────
# _plist_extract_key <plist> <KeyName> — prints the <string> or <integer>
# value immediately following <key>KeyName</key>; empty if not found or the
# file is malformed (fail-open: caller treats empty as "unknown").
_plist_extract_key() {
  local plist="$1" key="$2"
  awk -v k="<key>${key}</key>" '
    index($0, k) { found=1; next }
    found {
      if (match($0, /<string>.*<\/string>/)) {
        line=$0; sub(/.*<string>/,"",line); sub(/<\/string>.*/,"",line); print line; exit
      }
      if (match($0, /<integer>.*<\/integer>/)) {
        line=$0; sub(/.*<integer>/,"",line); sub(/<\/integer>.*/,"",line); print line; exit
      }
      if (/<\/dict>/ || /<key>/) exit   # next key/end-of-dict with no value seen — give up
    }
  ' "$plist" 2>/dev/null || true
}

# ── classify_agent_checkout <plist> ───────────────────────────────────────────
# Prints AGENT_CHECKOUT_BEHIND:<dir> when <plist>'s declared WorkingDirectory
# resolves to a git checkout that is behind the already-fetched
# origin/<default> (#1624). Reuses _behind_origin_default — the exact
# default_branch_of -> merge-base --is-ancestor mechanism classify_cron_checkout
# uses for BEHIND_MAIN — rather than reimplementing the comparison.
#
# FAIL-OPEN, silently, on every uncertain case: an absent WorkingDirectory key,
# a path that doesn't exist, or a path that isn't a git checkout each print
# nothing ("can't verify") — never a crash, never a false BEHIND claim. This
# mirrors classify_agent's own freshness-unknown convention for a marker-less
# agent: silence folds into the report's OK row rather than asserting a verdict
# on evidence we don't have.
classify_agent_checkout() {
  local plist="$1" wd
  wd="$(_plist_extract_key "$plist" WorkingDirectory)"
  [ -n "$wd" ] || { printf ''; return 0; }
  [ -d "$wd" ] || { printf ''; return 0; }
  is_git_repo "$wd" || { printf ''; return 0; }
  if [ "$(_behind_origin_default "$wd")" = "true" ]; then
    printf 'AGENT_CHECKOUT_BEHIND:%s' "$wd"
  else
    printf ''
  fi
  return 0
}

# ── Host-role ownership helpers (#531) ────────────────────────────────────────
# _host_in_agent_hosts — true iff this host is in the explicit AGENT_HOSTS list.
_host_in_agent_hosts() {
  local h _i=0
  while [ "$_i" -lt "${#AGENT_HOSTS[@]}" ]; do
    h="${AGENT_HOSTS[$_i]}"; _i=$((_i + 1))
    [ "$h" = "$RECONCILE_HOST" ] && return 0
  done
  return 1
}

# _agent_installed_here <plist> — is the agent declared by <plist> installed on
# THIS host? An installed launchd user agent lives in $AGENT_INSTALL_DIR (default
# ~/Library/LaunchAgents), matched by plist basename first (the shape
# `make install-launchd-all` produces) then, as a fallback, by declared Label.
# READ-ONLY — a stat/glob only, never a launchctl call.
_agent_installed_here() {
  local plist="$1" base label f flabel
  [ -d "$AGENT_INSTALL_DIR" ] || return 1
  base="$(basename "$plist")"
  [ -e "$AGENT_INSTALL_DIR/$base" ] && return 0
  label="$(_plist_extract_key "$plist" Label)"
  [ -n "$label" ] || return 1
  for f in "$AGENT_INSTALL_DIR"/*.plist; do
    [ -e "$f" ] || continue
    flabel="$(_plist_extract_key "$f" Label)"
    [ "$flabel" = "$label" ] && return 0
  done
  return 1
}

# _agent_owned_here <plist> — does THIS host own (and therefore run) the agent
# declared by <plist>? Explicit AGENT_HOSTS list wins when set; otherwise the
# install-marker auto-detect above. When false, the agent is another host's
# responsibility and classify_agent reports EXPECTED_ELSEWHERE, not drift.
_agent_owned_here() {
  local plist="$1"
  if [ "${#AGENT_HOSTS[@]}" -gt 0 ]; then
    _host_in_agent_hosts
    return $?
  fi
  _agent_installed_here "$plist"
}

# _this_host_owns_cron — does THIS host own the cron-checkout role? Explicit
# AGENT_HOSTS list wins when set; otherwise auto-detect: a host owns the cron
# role iff it has at least one of the declared launchd agents installed (the same
# automation-host signal). A host with none installed (a laptop) does not own the
# cron checkouts, so their absence is EXPECTED_ELSEWHERE rather than ABSENT.
_this_host_owns_cron() {
  if [ "${#AGENT_HOSTS[@]}" -gt 0 ]; then
    _host_in_agent_hosts
    return $?
  fi
  local d p _i=0
  while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
    d="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
    [ -d "$d" ] || continue
    for p in "$d"/*.plist; do
      [ -e "$p" ] || continue
      _agent_installed_here "$p" && return 0
    done
  done
  return 1
}

# ── classify_agent <plist> ────────────────────────────────────────────────────
classify_agent() {
  local plist="$1" label interval last_run age_s marker classes=""

  label="$(_plist_extract_key "$plist" Label)"
  if [ -z "$label" ]; then
    printf 'MALFORMED_PLIST:%s' "$(basename "$plist")"
    return 0
  fi

  # Host-role gate (#531): an agent this host does not own belongs to the agent host,
  # not here — report EXPECTED_ELSEWHERE (a non-drift class) rather than probing
  # launchctl and false-flagging it AGENT_UNLOADED on a non-owning laptop. It also
  # gates the checkout-currency check below: WorkingDirectory is a path on THIS
  # host's filesystem, meaningful only when this host is the one actually running
  # the agent from it.
  if ! _agent_owned_here "$plist"; then
    printf 'EXPECTED_ELSEWHERE:%s' "$label"
    return 0
  fi

  # WorkingDirectory currency (#1624) — an axis independent of load/freshness
  # state: a checkout can be behind whether the agent is loaded, unloaded, or
  # stale, so this is computed unconditionally rather than nested under one of
  # the exclusive early-returns below.
  classes="$(classify_agent_checkout "$plist")"
  [ -n "$classes" ] && classes="${classes} "

  if ! command -v launchctl >/dev/null 2>&1; then
    printf '%s' "$classes"   # fail-open: tool absent, no loaded-state verdict possible
    return 0
  fi

  if ! _env_reconcile_launchctl list 2>/dev/null | awk '{print $3}' | grep -xF "$label" >/dev/null; then
    printf '%sAGENT_UNLOADED:%s' "$classes" "$label"
    return 0
  fi

  interval="$(_plist_extract_key "$plist" StartInterval)"
  case "$interval" in '' | *[!0-9]*) interval="$AGENT_DEFAULT_CADENCE_S" ;; esac

  # ── Freshness oracle (#1173 / #904) ─────────────────────────────────────────
  # launchd touches StandardOutPath's mtime on EVERY wake — including a wake that
  # aborts in seconds having done nothing — so that mtime cannot distinguish "the
  # job ran" from "launchd opened the file" (a 0-byte log can carry a current
  # mtime; this is how the F#1170 silent-abort nights stayed invisible to the very
  # probe meant to catch them). The reliable signal is a heartbeat MARKER the job
  # itself writes on SUCCESSFUL completion; env-reconcile reads the marker, never
  # StandardOutPath. Agents opt in by `touch`-ing $AGENT_HEARTBEAT_DIR/<label>.ran
  # at the end of a successful run.
  marker="$AGENT_HEARTBEAT_DIR/${label}.ran"
  if [ -f "$marker" ]; then
    last_run="$(file_mtime "$marker")"
    age_s=$(( $(now_epoch) - last_run ))
    # Stale once the last SUCCESSFUL run is older than one full cadence: a single
    # missed or silently-aborted cycle leaves the marker untouched and trips this.
    if [ "$age_s" -gt "$interval" ]; then
      printf '%sAGENT_STALE:%s' "$classes" "$label"
      return 0
    fi
    printf '%s' "$classes"
    return 0
  fi

  # No heartbeat marker: the agent has not adopted the reliable signal, and
  # StandardOutPath mtime is untrustworthy (#1173), so we do NOT assert freshness
  # from it — a false-STALE every run is noise, and the false-FRESH it used to
  # emit was the F#1170 blind spot. The loaded-state check above still catches an
  # UNLOADED agent; freshness for a marker-less agent is reported as unknown
  # (nothing emitted) until it adopts the heartbeat. Fail-open. $classes (e.g. an
  # AGENT_CHECKOUT_BEHIND finding) still surfaces on its own independent axis.
  printf '%s' "$classes"
}

# ── agent_status_by_label <label> ─────────────────────────────────────────────
# Finds the launchd agent declaring Label <label> among the resolved
# LAUNCHD_DIRS registry and returns classify_agent's verdict for its plist —
# the same AGENT_STALE:<label> / AGENT_UNLOADED:<label> signal the
# direct-invocation report already emits (classify_agent above), reused
# (never reinvented) by /check-in's class-C activation discharge
# (claude/commands/check-in.md § Pending-activations ledger) for the
# launchd sub-case: a record's `locus` names an agent's declared Label, and
# discharge polls this instead of standing up a new "is the agent alive"
# sensor. Prints one of:
#   AGENT_STALE:<label>     loaded, but no evidence of a run within cadence
#   AGENT_UNLOADED:<label>  declared but not currently loaded
#   (empty)                 fresh — fired within its own declared cadence
# and exits 0 in all three cases. If no plist among LAUNCHD_DIRS declares
# <label>, prints nothing and exits 1 — "can't verify", the same fail-open
# shape as kernel_pin_tag_of's "not yet reached": the caller keeps the
# record open and reports it as unverifiable rather than guessing.
agent_status_by_label() {
  local label="$1" dir plist found_label
  local _i=0
  while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
    dir="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
    [ -d "$dir" ] || continue
    for plist in "$dir"/*.plist; do
      [ -e "$plist" ] || continue
      found_label="$(_plist_extract_key "$plist" Label)"
      if [ "$found_label" = "$label" ]; then
        classify_agent "$plist"
        return 0
      fi
    done
  done
  return 1
}

# ── Main enumeration + Emit — DIRECT-INVOCATION ONLY ─────────────────────────
# Guarded so this script is also safely SOURCEABLE as a library: a caller
# (e.g. /check-in's class-B and class-C activation discharge —
# claude/commands/check-in.md § Pending-activations ledger) can `source` this
# file with no args to pull in OPERATOR_CHECKOUTS (the consumer registry),
# LAUNCHD_DIRS, and the kernel_pin_tag_of / semver_ge / agent_status_by_label
# helpers above WITHOUT running the reconciler or hitting one of its
# `exit` calls (which, under `source`, would exit the *caller's* shell, not
# just return). Direct execution (`env-reconcile.sh [--format ...]`) is
# unaffected — this guard is true exactly when the script is its own $0.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

declare -a WT_ROOTS=()
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  _c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}.wt" ] && WT_ROOTS+=("$_c")
done
_i=0
while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
  _c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}.wt" ] && WT_ROOTS+=("$_c")
done

# Resolve once (#531): does THIS host own the cron-checkout role? On a
# non-owning host a cron checkout that is simply not present here is
# EXPECTED_ELSEWHERE, not ABSENT — the absence is the owning host's concern.
if _this_host_owns_cron; then HOST_OWNS_CRON=1; else HOST_OWNS_CRON=0; fi

CRON_LINES=""
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -n "$c" ] || continue
  cls="$(classify_cron_checkout "$c")"
  # A missing cron checkout on a host that does not own the cron role isn't
  # drift — reclassify ABSENT → EXPECTED_ELSEWHERE so a laptop stops reporting
  # the agent host's cron checkouts as ABSENT (#531).
  if [ "$cls" = "ABSENT" ] && [ "$HOST_OWNS_CRON" -eq 0 ]; then
    cls="EXPECTED_ELSEWHERE"
  fi
  if [ -z "$cls" ]; then
    CRON_LINES="${CRON_LINES}  OK           $c"$'\n'
  else
    case "$cls" in
      EXPECTED_ELSEWHERE)
        # Not this host's role (#531) — informational, never drift.
        CRON_LINES="${CRON_LINES}  EXPECTED     $c  [${cls}]"$'\n'
        ;;
      ABSENT | NOT_A_REPO)
        CRON_LINES="${CRON_LINES}  ${cls}$(printf '%*s' $((13 - ${#cls})) '')$c"$'\n'
        ;;
      *)
        CRON_LINES="${CRON_LINES}  DRIFT        $c  [${cls% }]"$'\n'
        add "- ⚠️ cron/kernel checkout drift: $c — ${cls% }" drift
        ;;
    esac
  fi
done

OPERATOR_LINES=""
_i=0
while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
  c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -n "$c" ] || continue
  cls="$(classify_operator_checkout "$c")"
  if [ -z "$cls" ]; then
    OPERATOR_LINES="${OPERATOR_LINES}  OK           $c"$'\n'
  else
    case "$cls" in
      ABSENT | NOT_A_REPO)
        OPERATOR_LINES="${OPERATOR_LINES}  ${cls}$(printf '%*s' $((13 - ${#cls})) '')$c"$'\n'
        ;;
      *)
        OPERATOR_LINES="${OPERATOR_LINES}  DRIFT        $c  [${cls% }]"$'\n'
        add "- ⚠️ operator checkout drift: $c — ${cls% }" drift
        # A stale vendored hook is only actionable with the command that re-syncs
        # it, so emit the remedy alongside the class in BOTH formats (the report
        # table below, and the FINDINGS block --format entry renders). Appended
        # via `add` WITHOUT the drift flag: it annotates the alarm already
        # counted above rather than counting as a second one.
        _j=0
        while [ "$_j" -lt "${#VENDORED_HOOKS[@]}" ]; do
          h="${VENDORED_HOOKS[$_j]}"; _j=$((_j + 1))
          # Match the token's TRAILING SPACE (_stale_vendored_hooks emits
          # `STALE_VENDORED_HOOK:<hook> `). Without it a hook basename that is a
          # prefix of another cross-matches, emitting a spurious re-sync line for
          # an in-sync hook the moment ENV_RECONCILE_VENDORED_HOOKS lists two
          # with a shared prefix.
          case "$cls" in
            *"STALE_VENDORED_HOOK:$h "*)
              remedy="$(_vendored_hook_sync_cmd "$c" "$h")"
              # The target lives in the consumer-side FLEET Makefile, not in this
              # kernel repo — so name the run location, or an operator acting on
              # this line from a kernel checkout just gets "No rule to make target".
              OPERATOR_LINES="${OPERATOR_LINES}               ↳ re-sync $h: $remedy  (run from the foundation checkout)"$'\n'
              add "  - remedy — re-sync $h into $c: \`$remedy\` (run from the foundation checkout)"
              ;;
          esac
        done
        ;;
    esac
  fi
done

WT_LINES=""
wt_checked=0
_i=0
while [ "$_i" -lt "${#WT_ROOTS[@]}" ]; do
  c="${WT_ROOTS[$_i]}"; _i=$((_i + 1))
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_checked=$((wt_checked + 1))
    cls="$(classify_worktree "$c" "$wt")"
    if [ -z "$cls" ]; then
      WT_LINES="${WT_LINES}  OK           $wt"$'\n'
    else
      WT_LINES="${WT_LINES}  DRIFT        $wt  [${cls}]"$'\n'
      add "- ⚠️ leaked worktree: $wt — ${cls}" drift
    fi
  done < <(find "${c}.wt" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done

AGENT_LINES=""
agent_checked=0
_i=0
while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
  d="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
  if [ -z "$d" ] || [ ! -d "$d" ]; then continue; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    agent_checked=$((agent_checked + 1))
    cls="$(classify_agent "$p")"
    if [ -z "$cls" ]; then
      AGENT_LINES="${AGENT_LINES}  OK           $p"$'\n'
    else
      case "$cls" in
        EXPECTED_ELSEWHERE:*)
          # Not this host's role (#531) — informational, never drift.
          AGENT_LINES="${AGENT_LINES}  EXPECTED     $p  [${cls}]"$'\n'
          ;;
        *)
          # cls may carry a trailing space when classify_agent combined an
          # AGENT_CHECKOUT_BEHIND token (its own field, always space-appended)
          # with nothing after it — strip it (same convention as the operator-
          # checkout emit site above) rather than print an empty trailing token.
          AGENT_LINES="${AGENT_LINES}  DRIFT        $p  [${cls% }]"$'\n'
          add "- ⚠️ launchd agent drift: $p — ${cls% }" drift
          ;;
      esac
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 1 -type f -name '*.plist' 2>/dev/null)
done

# ── Emit ───────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "entry" ]; then
  [ "$alarms" -eq 0 ] && exit 0   # clean → append nothing
  ts="$(date '+%Y-%m-%d %H:%M')"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  printf '### %s · env reconcile · %s\n' "$ts" "$host"
  printf -- '- **Decision:** dispose of %d environment-drift alarm(s) below.\n' "$alarms"
  printf -- '- **Findings:**\n'
  printf '%s' "$FINDINGS" | sed 's/^/  /'
  printf -- '- **Status:** open\n'
  exit 0
fi

echo "=== env reconcile ==="
echo "-- cron/kernel checkouts --"
printf '%s' "$CRON_LINES"
echo "-- operator/consumer checkouts --"
printf '%s' "$OPERATOR_LINES"
echo "-- worktrees ($wt_checked checked) --"
printf '%s' "$WT_LINES"
echo "-- launchd agents ($agent_checked checked) --"
printf '%s' "$AGENT_LINES"
echo "---"
if [ "$alarms" -gt 0 ]; then
  echo "DRIFT: $alarms"
else
  echo "OK"
fi
exit 0

fi # end direct-invocation guard
