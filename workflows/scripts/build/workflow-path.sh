#!/usr/bin/env bash
#
# workflow-path.sh — resolve the orchestrator a driver invokes, and REFUSE a
# silently stale one (temperloop#2027).
#
# THE SEAM THIS OWNS. All three drivers — /build (build.md Step 3), /sweep
# (sweep.md Step 0.3) and /fix (fix.md Step 0) — invoke the same per-level
# orchestrator through the Workflow tool's `scriptPath`. Until this script,
# all three named the same literal, `$HOME/.claude/workflows/build-level.mjs`,
# and that literal carried TWO defects at one seam:
#
#   1. IT IS NOT INVOCABLE AS WRITTEN. The Workflow tool refuses a scriptPath
#      outside the session's working directory, verbatim:
#
#        scriptPath must be a script path this tool returned, or a file you
#        can already read (the working directory or a directory you have
#        added): /Users/<user>/.claude/workflows/build-level.mjs
#
#      $HOME/.claude is outside the checkout, so every drive depended on the
#      invoker noticing and silently falling back to the repo-relative copy —
#      an undocumented fallback no spec named and no test covered.
#
#   2. WHEN IT IS USABLE, IT IS A SECOND SOURCE OF TRUTH WITH NO SYNC. The
#      installed copy is a plain file, not a symlink, and nothing in this repo
#      installs or refreshes it. It drifts on every merge, permanently, and a
#      run against it executes pre-fix machinery and reports success. Three
#      live reproductions, the latest 347 lines behind the checkout copy; two
#      earlier ones are recorded in doctor.sh's own detector header, including
#      an overnight run in which every workflow invocation executed a six-day-
#      stale orchestrator.
#
# THE FIX IS RESOLUTION, NOT SYNC. The first choice is the CHECKOUT copy
# ($repoRoot/claude/workflows/<engine>): the tool accepts it (it is inside the
# working directory), and it is the copy the session is editing and reasoning
# about — so the two-copies problem is removed rather than managed. Keeping an
# installed copy in sync would have required new machinery to maintain a
# duplicate that has no owner; deleting the duplicate from the resolution path
# needs none.
#
# THIS SCRIPT IS THE BELT FOR THE PATHS THAT STILL RESOLVE AN INSTALLED COPY —
# a consuming repo that vendors only the install, or an operator who names one
# explicitly. There, freshness cannot be assumed, so the gate REFUSES on drift
# before the first invocation instead of letting stale machinery run silently.
#
# IT REUSES THE EXISTING DETECTOR — it does not grow a second one.
# `workflows/scripts/install/doctor.sh --only=installed-workflow-drift`
# (temperloop#1397) already compares every installed ~/.claude/workflows/*.mjs
# against this checkout's claude/workflows/*.mjs by sha256 and classifies each
# as OK / DRIFT / ABSENT / UNKNOWN / SKIPPED. That function stays the single
# definition of "is the installed copy stale"; this script is a second
# ENTRYPOINT to it, wearing a closed-outcome verdict a driver can branch on.
#
# USAGE
#   workflow-path.sh resolve <repo-root> [<candidate-path>]
#
#       Stdout: ONE JSON line — the closed-outcome convention every script in
#       this directory uses (worktree.sh / pr.sh / ci-poll.sh /
#       handoff-capability.sh). Stderr: the human-readable notice, on every
#       outcome except the clean checkout resolution.
#
#         {"outcome":"WORKFLOW_PATH_CHECKOUT","path":…,"notice":null,"remedy":null}
#             The checkout copy. Exit 0. The expected steady state.
#
#         {"outcome":"WORKFLOW_PATH_INSTALLED_IN_SYNC","path":…,"notice":…,"remedy":…}
#             An installed copy, VERIFIED byte-identical to the checkout copy.
#             Exit 0 — but the notice still prints, because a copy that is in
#             sync right now has no owner keeping it that way.
#
#         {"outcome":"WORKFLOW_PATH_STALE","path":null,"notice":…,"remedy":…}
#             An installed copy that DIFFERS from the checkout copy. REFUSAL:
#             exit 1 and NO path is printed, so a caller that reads `.path`
#             gets nothing to invoke rather than a stale engine.
#
#         {"outcome":"WORKFLOW_PATH_INDETERMINATE","path":…,"reason":…,
#          "notice":…,"remedy":…}
#             An out-of-checkout path whose freshness could NOT be established
#             (nothing to compare it against, uncomparable, or outside the
#             detector's scope). Exit 0 with a loud notice — never read as a
#             pass. An unknown must not look like a clean resolution; that
#             collapse is the failure this whole script exists to end.
#
#         {"outcome":"ERROR","error":…}   + exit 2 (usage / unreadable root)
#
#       Only ERROR and the STALE refusal exit non-zero. INDETERMINATE
#       deliberately does not halt a drive: an engine whose freshness is
#       unknowable is not evidence that it is stale, and the caller has been
#       told, loudly, in the only place an operator will read it.
#
#   workflow-path.sh path <repo-root> [<candidate-path>]
#       The resolved path alone on stdout, for `workflowPath="$(…)"`. Same
#       exit codes and same stderr notices; prints NOTHING on a refusal.
#
# ENGINE BASENAME: `build-level.mjs`, a constant and deliberately not a
# setting. A checkout that ships the per-level orchestrator under another name
# passes that path as <candidate-path> instead — one channel, already gated,
# rather than a tunable nobody asked for.
#
# shellcheck shell=bash
set -uo pipefail

ENGINE_BASENAME="build-level.mjs"

# ---------------------------------------------------------------------------
# _json_escape <string> — minimal JSON string escaping (no jq dependency:
# this gate runs in front of every drive, including one whose checkout has
# not provisioned jq yet).
# ---------------------------------------------------------------------------
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_json_str() {
  if [[ -z "${1+x}" || -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(_json_escape "$1")"; fi
}

_die() {
  printf '{"outcome":"ERROR","error":%s}\n' "$(_json_str "$1")"
  printf 'workflow-path.sh: %s\n' "$1" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# _physical <path> — the physically-resolved path, or the input unchanged when
# it cannot be resolved (a path that does not exist yet).
# ---------------------------------------------------------------------------
_physical() {
  local p="$1" d b
  d="$(dirname -- "$p")"
  b="$(basename -- "$p")"
  if d="$(cd "$d" 2>/dev/null && pwd -P)"; then
    printf '%s/%s' "$d" "$b"
  else
    printf '%s' "$p"
  fi
}

# ---------------------------------------------------------------------------
# _drift_status <report> <installed-path> — the detector's verdict token for
# ONE path, read out of doctor.sh's focused report. Prints DRIFT / OK /
# ABSENT / UNKNOWN, or nothing when the report carries no line for that path
# (e.g. SKIPPED: the checkout ships no workflows to compare against).
#
# Parses rather than recomputes, deliberately: the comparison itself stays in
# the one detector temperloop#1397 already ships.
# ---------------------------------------------------------------------------
_drift_status() {
  local report="$1" want="$2" line st p
  while IFS= read -r line; do
    [[ "$line" =~ ^\ \ ([A-Z]+)\ +(/.*)$ ]] || continue
    st="${BASH_REMATCH[1]}"
    p="${BASH_REMATCH[2]}"
    if [[ "$p" == "$want" ]]; then printf '%s' "$st"; return 0; fi
  done <<<"$report"
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  resolve|path) ;;
  ""|-h|--help) _die "usage: workflow-path.sh resolve|path <repo-root> [<candidate-path>]" ;;
  *)            _die "unknown command: ${cmd} (expected: resolve|path)" ;;
esac

repo_root_in="${2:-}"
candidate_in="${3:-}"

[[ -n "$repo_root_in" ]] || _die "usage: workflow-path.sh ${cmd} <repo-root> [<candidate-path>]"
repo_root="$(cd "$repo_root_in" 2>/dev/null && pwd -P)" \
  || _die "repo root is not a readable directory: ${repo_root_in}"

checkout_path="${repo_root}/claude/workflows/${ENGINE_BASENAME}"
home_dir="${HOME:-}"
installed_path=""
[[ -n "$home_dir" ]] && installed_path="${home_dir}/.claude/workflows/${ENGINE_BASENAME}"

# --- Resolution order ------------------------------------------------------
# 1. an explicitly named candidate (a consuming repo, or an operator pinning a
#    specific engine) — honoured, and then gated;
# 2. the checkout copy — the answer in every normal drive;
# 3. the installed copy — the last resort, and always gated.
if [[ -n "$candidate_in" ]]; then
  resolved="$candidate_in"
elif [[ -f "$checkout_path" ]]; then
  resolved="$checkout_path"
elif [[ -n "$installed_path" ]]; then
  resolved="$installed_path"
else
  _die "no engine found: ${checkout_path} is absent and HOME is unset"
fi

resolved_phys="$(_physical "$resolved")"
checkout_phys="$(_physical "$checkout_path")"

# emit <outcome> <path-or-empty> <reason-or-empty> <notice> <remedy> <exit>
#
# `notice` is ONE line — `claude/message-schema.md` § Degradation notice in its
# mode-2 minimal form. The detector's multi-line report is operator DETAIL, not
# part of the verdict, so it goes to stderr via $EMIT_DETAIL and never into the
# JSON a caller parses.
EMIT_DETAIL=""
emit() {
  local outcome="$1" path="$2" reason="$3" notice="$4" remedy="$5" code="$6"
  if [[ "$cmd" == "path" ]]; then
    [[ -n "$path" ]] && printf '%s\n' "$path"
  elif [[ -n "$reason" ]]; then
    printf '{"outcome":"%s","path":%s,"reason":%s,"notice":%s,"remedy":%s}\n' \
      "$outcome" "$(_json_str "$path")" "$(_json_str "$reason")" \
      "$(_json_str "$notice")" "$(_json_str "$remedy")"
  else
    printf '{"outcome":"%s","path":%s,"notice":%s,"remedy":%s}\n' \
      "$outcome" "$(_json_str "$path")" "$(_json_str "$notice")" "$(_json_str "$remedy")"
  fi
  [[ -n "$notice" ]] && printf '%s\n' "$notice" >&2
  [[ -n "$EMIT_DETAIL" ]] && printf '%s\n' "$EMIT_DETAIL" >&2
  exit "$code"
}

# --- The steady state: the checkout copy -----------------------------------
if [[ "$resolved_phys" == "$checkout_phys" ]]; then
  [[ -f "$resolved" ]] || _die "the checkout engine is missing: ${checkout_path}"
  emit WORKFLOW_PATH_CHECKOUT "$resolved" "" "" "" 0
fi

# --- Everything else is an out-of-checkout copy: gate it -------------------
REMEDY="re-run the install from the checkout you intend to be canonical, or drop the explicit engine path so ${checkout_path} resolves — that copy is the one this session is editing, and the Workflow tool accepts it because it is inside the working directory."

if [[ -z "$installed_path" || "$resolved_phys" != "$(_physical "$installed_path")" ]]; then
  emit WORKFLOW_PATH_INDETERMINATE "$resolved" \
    "outside the installed-workflow drift detector's scope (${installed_path:-\$HOME/.claude/workflows} is what it compares)" \
    "warning — ${resolved} is not the checkout copy and its freshness could NOT be checked: the drift detector only compares \$HOME/.claude/workflows. This is NOT a clean result; the engine may be stale, and a stale engine runs old logic and reports success." \
    "$REMEDY" 0
fi

doctor_sh="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../install" 2>/dev/null && pwd -P)/doctor.sh"
if [[ ! -f "$doctor_sh" ]]; then
  emit WORKFLOW_PATH_INDETERMINATE "$resolved" \
    "the drift detector is absent from this checkout (expected workflows/scripts/install/doctor.sh)" \
    "warning — ${resolved} is an installed copy and its freshness could NOT be checked: this checkout ships no drift detector. This is NOT a clean result — an absent check is never a pass." \
    "$REMEDY" 0
fi

report="$(bash "$doctor_sh" --only=installed-workflow-drift "$repo_root" 2>&1)"
status="$(_drift_status "$report" "$installed_path")"

case "$status" in
  DRIFT)
    EMIT_DETAIL="$report"
    emit WORKFLOW_PATH_STALE "" "" \
      "REFUSED — ${resolved} is STALE: it differs from this checkout's ${checkout_path}, so running it would execute machinery this checkout has already replaced and report success. No engine path was resolved." \
      "$REMEDY" 1
    ;;
  OK)
    emit WORKFLOW_PATH_INSTALLED_IN_SYNC "$resolved" "" \
      "warning — resolved the INSTALLED engine ${resolved} rather than the checkout copy. It is byte-identical to ${checkout_path} right now, but nothing installs or refreshes it, so it drifts on the next merge with no owner." \
      "$REMEDY" 0
    ;;
  ABSENT)
    emit WORKFLOW_PATH_INDETERMINATE "$resolved" "no installed copy exists at ${installed_path}" \
      "warning — ${resolved} does not exist. Invoking it would fail outright rather than run stale machinery, but nothing here resolved an engine you can run." \
      "$REMEDY" 0
    ;;
  *)
    emit WORKFLOW_PATH_INDETERMINATE "$resolved" \
      "the drift detector returned ${status:-no verdict} for ${installed_path}" \
      "warning — ${resolved} is an installed copy and its freshness could NOT be established (${status:-the detector compared nothing: this checkout may ship no claude/workflows/*.mjs}). This is NOT a clean result — an indeterminate check is never a pass." \
      "$REMEDY" 0
    ;;
esac
