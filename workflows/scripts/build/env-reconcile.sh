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
#                              AGENT_UNLOADED  declared but not in
#                                              `launchctl list`
#                              AGENT_STALE     loaded, but no evidence of a
#                                              run within its own cadence
#                            Override: ENV_RECONCILE_LAUNCHD_DIRS
#                            (space-separated dirs to glob *.plist in).
#
# Usage:
#   env-reconcile.sh [--format report|entry]
#
#   --format report   human-readable table + summary (default)
#   --format entry    a `### … Status: open` vault block (modeled on
#                      drain/vault_hygiene_report.sh --format entry) —
#                      emits NOTHING and exits 0 when no drift is found
#
# Env overrides (all optional; space-separated path lists unless noted):
#   ENV_RECONCILE_CRON_CHECKOUTS
#   ENV_RECONCILE_OPERATOR_CHECKOUTS
#   ENV_RECONCILE_LAUNCHD_DIRS
#   ENV_RECONCILE_STALE_UNTRACKED_DAYS      (default 7)
#   ENV_RECONCILE_AGENT_LOG_DIR             (default $HOME/Library/Logs)
#   ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S   (default 86400 — used when a
#                                            plist declares no StartInterval)
#
# READ-ONLY / FAIL-OPEN contract: this script never runs `git fetch`, never
# writes a file, never calls `launchctl load/unload`, never invokes `gh` in
# any but a read (`pr view`) mode. A missing tool (gh, launchctl), a
# non-existent checkout, or a malformed plist is skipped/degraded rather than
# aborting — the script always exits 0 except on a genuine usage error (2).
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) with BSD-vs-
# GNU stat fallbacks, so it runs on the macOS dev shell as well as Linux CI.
# It is a DIRECTLY-INVOKED script (env-hygiene-report.sh + /tidy call it by
# bare path) — tracked 100755, unlike its sourced-only sibling lib/merged-detect.sh.

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
AGENT_LOG_DIR="${ENV_RECONCILE_AGENT_LOG_DIR:-$HOME/Library/Logs}"
AGENT_DEFAULT_CADENCE_S="${ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S:-86400}"

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
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
now_epoch() { date +%s; }

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

# ── classify_cron_checkout <repo> ─────────────────────────────────────────────
# Prints zero or more space-separated class tokens (empty = OK).
classify_cron_checkout() {
  local repo="$1" classes="" branch default head origin_head
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
  else
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || head=""
    if [ -n "$head" ] && git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$default"; then
      origin_head="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" || origin_head=""
      if [ -n "$origin_head" ] && [ "$head" != "$origin_head" ] \
        && git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
        classes="${classes}BEHIND_MAIN "
      fi
    fi
  fi

  printf '%s' "$classes"
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

  if ! git -C "$repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt_abs"; then
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

# ── classify_agent <plist> ────────────────────────────────────────────────────
classify_agent() {
  local plist="$1" label interval log_path last_run age_s

  label="$(_plist_extract_key "$plist" Label)"
  if [ -z "$label" ]; then
    printf 'MALFORMED_PLIST:%s' "$(basename "$plist")"
    return 0
  fi

  if ! command -v launchctl >/dev/null 2>&1; then
    printf ''   # fail-open: tool absent, no loaded-state verdict possible
    return 0
  fi

  if ! _env_reconcile_launchctl list 2>/dev/null | awk '{print $3}' | grep -qxF "$label"; then
    printf 'AGENT_UNLOADED:%s' "$label"
    return 0
  fi

  interval="$(_plist_extract_key "$plist" StartInterval)"
  case "$interval" in '' | *[!0-9]*) interval="$AGENT_DEFAULT_CADENCE_S" ;; esac

  log_path="$(_plist_extract_key "$plist" StandardOutPath)"
  [ -n "$log_path" ] || log_path="$AGENT_LOG_DIR/${label}.log"

  if [ -f "$log_path" ]; then
    last_run="$(file_mtime "$log_path")"
    age_s=$(( $(now_epoch) - last_run ))
    if [ "$age_s" -gt "$interval" ]; then
      printf 'AGENT_STALE:%s' "$label"
      return 0
    fi
  fi

  printf ''
}

# ── Main enumeration ──────────────────────────────────────────────────────────
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

CRON_LINES=""
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -n "$c" ] || continue
  cls="$(classify_cron_checkout "$c")"
  if [ -z "$cls" ]; then
    CRON_LINES="${CRON_LINES}  OK           $c"$'\n'
  else
    case "$cls" in
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
      AGENT_LINES="${AGENT_LINES}  DRIFT        $p  [${cls}]"$'\n'
      add "- ⚠️ launchd agent drift: $p — ${cls}" drift
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
