#!/usr/bin/env bash
#
# legacy-host-preflight.sh — registry-driven HOST-STATE preflight for legacy
# host-config paths a release has REMOVED (temperloop#908).
#
# ── The gap this closes ─────────────────────────────────────────────────
# A `gate_check:` predicate on a removal item historically asserted the
# REPO artifact that describes a migration ("the plist in the repo was
# repointed", "the fallback code path was deleted") rather than the
# CONSUMABLE actually live on the operator's HOST. Two real instances:
#
#   1. foundation#1419 — the repo plist was repointed at pipeline-cron.sh,
#      but the INSTALLED ~/Library/LaunchAgents/com.foundation.funnel-cron.plist
#      still ran the deleted funnel-cron.sh stub. The plan note's gate_check:
#      tested the repo file, so it read TRUE while the host stayed broken.
#   2. temperloop#165 — v0.19.0 removed board.sh's legacy
#      $XDG_CONFIG_HOME/foundation/boards.conf read. On a host where that
#      legacy file was the ONLY record of a fleet backend cutover
#      (board.{3,4,5,6}.backend=issues, temperloop#470-473), and no
#      $XDG_CONFIG_HOME/temperloop/boards.conf (its v0.15.0 successor) or
#      repo-local boards.conf existed either, every board read/write
#      silently reverted to the built-in default (Projects-v2) with no
#      error and no log line.
#
# Both instances shared the same near-miss: the pre-removal code ALREADY
# printed an advisory (board.sh's "NOTE — legacy machine conf ... is no
# longer read", pipeline-cron.sh's "NOTE: ... is deprecated" per legacy env
# read) — but that advisory is emitted from the DEPRECATED-BUT-STILL-WORKING
# state, on STDERR, which nobody watches unattended. Once the removal lands
# the advisory is GONE too, so the failure mode flips from noisy-and-working
# to silent-and-wrong at exactly the moment the operator stops being warned.
# A mechanism that only warns while things still work is the thing being
# fixed here: this script turns "print a NOTE if you happen to be watching"
# into a definitive, registry-driven, exit-code-bearing HOST assertion,
# wired into `make doctor` (workflows/scripts/install/doctor.sh) and
# therefore into every `temperloop update` post-checkout run
# (bin/subcommands/update.sh, run_post_checkout()) — the two places a
# release actually lands on a host.
#
# ── The registry (extend this for every future removal) ────────────────
# LEGACY_HOST_PREFLIGHT_REGISTRY below is the single list a future removal
# adds ONE row to (plus its own tiny `legacy_check_<id>` predicate
# function). Each predicate inspects host state directly — never a repo
# artifact — and reports exactly one of three verdicts:
#
#   ABSENT           the legacy consumable never existed on this host (a
#                     fresh install, or a host that was never on the old
#                     path). Never a failure — this IS the graceful-
#                     degradation case the acceptance bar names.
#   MIGRATED          the legacy consumable exists (or existed) AND the
#                     host has already moved to its replacement.
#   LIVE-UNMIGRATED   the legacy consumable is present AND STILL BEING
#                     READ/RUN, with no successor in place — the exact
#                     silent-and-wrong state both instances above produced.
#
# A predicate returns 0 for ABSENT/MIGRATED and 1 for LIVE-UNMIGRATED; the
# overall script (and `check_legacy_host_config()` in doctor.sh) is
# non-zero iff ANY registry entry is LIVE-UNMIGRATED.
#
# ── Sourced or executed ──────────────────────────────────────────────────
# Sourced (doctor.sh does this): defines the registry + functions, runs
# nothing — the execute-guard at the bottom only fires on direct execution
# (mirrors release.sh's own sourced/executed split). Executed directly, it
# is a standalone release-cut preflight:
#
#   bash workflows/scripts/install/legacy-host-preflight.sh
#
# Exit codes: 0 = every entry ABSENT or MIGRATED. 1 = at least one entry
# LIVE-UNMIGRATED (see the printed remediation line for each).
#
# Hermetic / test seam: every predicate reads ONLY $HOME and
# $XDG_CONFIG_HOME (both already in setting-registry.tsv's generic
# passthrough allowlist — no new registered setting needed), so a test
# isolates a fixture host with `env -i HOME=<tmp> XDG_CONFIG_HOME=<tmp>
# PATH="$PATH" bash legacy-host-preflight.sh` (see
# workflows/scripts/tests/test_legacy_host_preflight.sh), exactly the
# idiom workflows/scripts/tests/test_doctor_knowledge_root.sh already uses.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) — same
# constraint as the rest of workflows/scripts/install/*.sh.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# legacy_check_funnel_cron_plist — INSTANCE 1 (foundation#1419).
#
# LIVE iff the installed launchd agent plist exists on this host at all
# (checked under $HOME, never the repo — the repo's own plist living under
# infra/launchd/ is exactly the "artifact that merely describes it" the
# issue calls out; only the INSTALLED copy under ~/Library/LaunchAgents
# is what launchd actually runs). UNMIGRATED iff that installed copy's
# ACTUAL ProgramArguments (never its surrounding XML comments — the real
# plist ships a header comment naming the installer script
# infra/launchd/install-funnel-cron.sh, whose OWN filename substring-
# matches "funnel-cron.sh" and would false-positive a naive whole-file
# grep) still names the deleted funnel-cron.sh stub instead of its
# pipeline-cron.sh successor — the precise drift: the repo plist was
# repointed, but this on-disk copy was never re-synced, so launchd goes on
# invoking a script that no longer exists in the repo it targets.
#
# Comments are stripped with the POSIX `/<!--/,/-->/d` range-delete idiom
# (no GNU-only flags, no PlistBuddy dependency — this check must degrade
# the same way on every host, not only macOS) BEFORE the content match, so
# only the plist's real `<string>…</string>` values are ever inspected.
# ---------------------------------------------------------------------------
legacy_check_funnel_cron_plist() {
  local plist="${HOME:-}/Library/LaunchAgents/com.foundation.funnel-cron.plist"

  if [ ! -f "$plist" ]; then
    printf 'ABSENT|no installed launchd agent at %s\n' "$plist"
    return 0
  fi

  if sed '/<!--/,/-->/d' "$plist" 2>/dev/null | grep '<string>[^<]*funnel-cron\.sh</string>' >/dev/null; then
    printf 'LIVE-UNMIGRATED|%s still references the deleted funnel-cron.sh stub — re-run the launchd install (infra/launchd, or launchctl bootout + bootstrap the current com.foundation.funnel-cron.plist) so it invokes pipeline-cron.sh instead\n' "$plist"
    return 1
  fi

  printf 'MIGRATED|%s no longer references funnel-cron.sh\n' "$plist"
  return 0
}

# ---------------------------------------------------------------------------
# legacy_check_foundation_boards_conf — INSTANCE 2 (temperloop#165, v0.19.0).
#
# LIVE iff the legacy machine-level boards.conf still exists on this host.
# UNMIGRATED iff its v0.15.0 successor
# ($XDG_CONFIG_HOME/temperloop/boards.conf) does NOT — i.e. board.sh's
# discovery order (docs/config-precedence.md) has nowhere left to find
# whatever the legacy file recorded (most concretely a fleet backend
# cutover, board.<N>.backend=issues, that exists ONLY in the legacy file),
# so it silently falls through to the built-in case map instead.
# ---------------------------------------------------------------------------
legacy_check_foundation_boards_conf() {
  local xdg="${XDG_CONFIG_HOME:-${HOME:-}/.config}"
  local new_f="${xdg}/temperloop/boards.conf"
  local old_f="${xdg}/foundation/boards.conf"

  if [ ! -f "$old_f" ]; then
    printf 'ABSENT|no legacy machine conf at %s\n' "$old_f"
    return 0
  fi

  if [ -f "$new_f" ]; then
    printf 'MIGRATED|%s exists — the legacy %s is superseded\n' "$new_f" "$old_f"
    return 0
  fi

  printf 'LIVE-UNMIGRATED|%s exists but %s does not — board.sh no longer falls back to the legacy path (removed v0.19.0), so any entries recorded ONLY in the legacy file (e.g. board.N.backend=issues) are now silently invisible; move it: mkdir -p %s \&\& mv %s %s\n' \
    "$old_f" "$new_f" "${xdg}/temperloop" "$old_f" "$new_f"
  return 1
}

# ---------------------------------------------------------------------------
# The registry itself — id|description|checker-function, one row per
# tracked removal. Add a row + its `legacy_check_<id>` function for every
# future removed legacy host-config path; nothing else in this file, in
# doctor.sh, or in the caller needs to change.
# ---------------------------------------------------------------------------
LEGACY_HOST_PREFLIGHT_REGISTRY=(
  "funnel-cron-plist|foundation#1419 — installed launchd agent must not still run the deleted funnel-cron.sh stub|legacy_check_funnel_cron_plist"
  "foundation-boards-conf|temperloop#165 (v0.19.0) — legacy \$XDG_CONFIG_HOME/foundation/boards.conf read removed|legacy_check_foundation_boards_conf"
)

# ---------------------------------------------------------------------------
# legacy_host_preflight_run — walk the registry, print one line per entry,
# return non-zero iff any entry is LIVE-UNMIGRATED. Callable directly by a
# sourcing caller (doctor.sh) or via this file's own execute-guard below.
# ---------------------------------------------------------------------------
legacy_host_preflight_run() {
  local overall=0 entry id desc fn out rc verdict detail

  for entry in "${LEGACY_HOST_PREFLIGHT_REGISTRY[@]}"; do
    IFS='|' read -r id desc fn <<<"$entry"
    out="$("$fn")"
    rc=$?
    verdict="${out%%|*}"
    detail="${out#*|}"
    printf '  %-16s  %-20s  %s\n' "$verdict" "$id" "$desc"
    printf '      %s\n' "$detail"
    if [ "$rc" -ne 0 ]; then
      overall=1
    fi
  done

  return "$overall"
}

# Execute-guard: run the preflight only when this file is RUN, not when
# SOURCED (mirrors release.sh / doctor.sh's own sourced libs).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  printf 'Legacy host-config preflight — registry-driven host-state check (temperloop#908):\n\n'
  legacy_host_preflight_run
  status=$?
  echo
  if [ "$status" -ne 0 ]; then
    echo "legacy-host-preflight: one or more legacy host-config paths are LIVE and UNMIGRATED — see above."
  else
    echo "legacy-host-preflight: OK — every registered legacy host-config path is absent or migrated."
  fi
  exit "$status"
fi
