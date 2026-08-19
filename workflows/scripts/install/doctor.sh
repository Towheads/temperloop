#!/usr/bin/env bash
# make doctor — verify managed install links and report drift.
#
# Sources workflows/scripts/install/links.sh for the canonical link enumeration,
# then classifies each managed path and prints a status table.
#
# Status codes (printed per-entry and in the summary):
#
#   OK        symlink present and points at expected source
#             OR managed real file / shim is present
#   MISSING   target path does not exist (and is not a broken symlink)
#   DRIFT     symlink present but points at a DIFFERENT source
#   SHADOWED  a real file/directory exists where a symlink is expected
#   DANGLING  symlink present but its target path does not exist on disk
#
# Exit codes:
#   0   all entries are OK
#   1   one or more entries are non-OK
#
# Usage: bash workflows/scripts/install/doctor.sh [<foundation-root>]
#        (foundation-root defaults to the repo root detected from this script's path)
#
# shellcheck shell=bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve FOUNDATION (repo root) from this script's location or an argument.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION="${1:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
export FOUNDATION

# Source the shared enumeration helper.
# shellcheck source=links.sh
source "${SCRIPT_DIR}/links.sh"

# Source the shared gitignore-safety helper (temperloop#569/#570 dedup —
# check_reviewer_coverage() below calls gitignore_ensure_entry() directly
# instead of a private, doctor-local reimplementation).
GITIGNORE_SAFETY_SH="${SCRIPT_DIR}/gitignore-safety.sh"
if [ ! -f "$GITIGNORE_SAFETY_SH" ]; then
  echo "doctor.sh: missing sibling script: $GITIGNORE_SAFETY_SH" >&2
  exit 1
fi
# shellcheck source=gitignore-safety.sh
source "$GITIGNORE_SAFETY_SH"

# ---------------------------------------------------------------------------
# classify_entry <target> <expected_source> <kind>
#
# Prints the status string for a single managed path.
# ---------------------------------------------------------------------------
classify_entry() {
  local target="$1"
  local expected_src="$2"
  local kind="$3"

  if [[ "$kind" == "real" || "$kind" == "claude-md" ]]; then
    # settings.json (real) / composed CLAUDE.md (claude-md) — both are
    # expected to be a real (non-symlink) regular file; same classification.
    if [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "OK"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      echo "DRIFT"   # exists but not a plain file (e.g. is a symlink or directory)
    else
      echo "MISSING"
    fi
    return
  fi

  if [[ "$kind" == "gh-shim" ]]; then
    # gh logger shim — managed real copy, recognised by 'call-logger' marker.
    if [ -f "$target" ] && ! [ -L "$target" ] && grep -q 'call-logger' "$target" 2>/dev/null; then
      echo "OK"
    elif [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "DRIFT"   # real file but not our shim
    elif [ -L "$target" ]; then
      echo "DRIFT"   # should be a real file, not a symlink
    elif [ -e "$target" ]; then
      echo "DRIFT"   # something else (directory?)
    else
      echo "MISSING"
    fi
    return
  fi

  # kind == "symlink"
  if [ -L "$target" ]; then
    local actual_src
    actual_src="$(readlink "$target")"
    if [[ "$actual_src" == "$expected_src" ]]; then
      if [ -e "$target" ]; then
        echo "OK"
      else
        echo "DANGLING"
      fi
    else
      echo "DRIFT"
    fi
  elif [ -e "$target" ]; then
    echo "SHADOWED"
  else
    echo "MISSING"
  fi
}

# ---------------------------------------------------------------------------
# check_knowledge_root — foundation Epic B "layered CLAUDE.md" / the Epic A
# (#762) knowledge_store split-brain guard: EVERY consumer of ks_root() must
# resolve the SAME KNOWLEDGE_STORE_ROOT regardless of which files it happens
# to source first. A mismatch means the two planes silently split the
# corpus: e.g. a script-plane consumer that sources build.config.sh writes
# into one directory while a bare-env consumer (a hook, a launchd agent —
# session-start-drain.sh is the motivating case) that sources only
# knowledge_store.sh reads/writes another.
#
# REWRITTEN (foundation#1332): the prior version of this check compared
# ks_root() against a root derived from KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE
# (workflows/scripts/lib/knowledge_store_obsidian.sh) — but that setting's
# ONLY default is itself "$(ks_root)/.obsidian/plugins/.../data.json", and
# nothing in this tree ever sets it independently. So the old check compared
# a value to itself: its MISMATCH branch was dead code that could never
# fire. Worse, its resolution subshell sourced build.config.sh FIRST, which
# directly sources the operator's rung-3 machine conf (BUILD_CONFIG_MACHINE)
# into scope before ks_root() ever ran its own `:=` — so the old check could
# only ever observe the ALREADY-correct plane, never the bare-env plane it
# was nominally guarding. This is exactly how a 218-drain, 16-consecutive-day
# split-brain outage (temperloop#1328/foundation#1328, fixed for real
# consumers by temperloop#771's _ks_machine_conf_root()) ran with this check
# reporting green the whole time.
#
# The rewrite compares TWO independently-resolved planes instead:
#
#   Plane A (script-plane) — sources build.config.sh, then knowledge_store.sh,
#     then calls ks_root(). build.config.sh directly sources the rung-3
#     machine conf into this subshell's scope, so this is the root any
#     consumer that goes through the full build/sweep stack sees — the same
#     value install-claude-md.sh renders as the vault "Store root:" line.
#
#   Plane B (bare-env) — sources ONLY knowledge_store.sh, then calls
#     ks_root(). This is exactly what a bare hook or launchd agent sees: no
#     build.config.sh in the chain, so ks_root()'s own `_ks_machine_conf_root
#     || _ks_default_root` fallback (temperloop#771) is what resolves it.
#
# A mismatch here is real and actionable: it means the rung-3 machine conf
# (or its KNOWLEDGE_STORE_MACHINE_CONF pointer) is broken or inconsistent
# with whatever build.config.sh itself sees, so the bare-env plane silently
# resolves a different root than the script-plane one.
#
# AGREEMENT ARM (foundation#1340): equality catches a SPLIT root but is blind
# to a UNIFORMLY WRONG one — with the machine conf absent both planes fall
# through to _ks_default_root(), agree, and the check used to print a bare OK
# over a root that is not the store. Since nothing in this tree installs or
# verifies that conf, it is an untracked SPOF, and the plain-files backend's
# `mkdir -p` on append means a wrong root is silently CREATED rather than
# erroring. So when the planes agree, the check now also reports the root's
# PROVENANCE (env / machine-conf / default-fallback) and downgrades OK to WARN
# for default-fallback — the one case where agreement proves nothing. Provenance
# rather than a store-shaped probe: the only store-identity signal available
# (`.obsidian/`) is an overlay artifact a kernel-only install does not have,
# whereas "did anything configure this?" needs no such signal. The WARN is
# advisory (return 0) — a fresh install with no store configured yet lands here
# legitimately, and the defect being closed was a false OK, not a missing FAIL.
#
# Runs fully offline: sourcing build.config.sh / knowledge_store.sh does no
# network I/O (only functions never called here would).
# ---------------------------------------------------------------------------
check_knowledge_root() {
  local build_config="${FOUNDATION}/workflows/scripts/build/build.config.sh"
  local ks_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"

  printf '\nKnowledge-store root check:\n'

  if [[ ! -f "$build_config" || ! -f "$ks_lib" ]]; then
    printf '  SKIPPED (config files not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  local plane_a plane_b
  plane_a="$(
    set -e
    # shellcheck source=/dev/null
    source "$build_config"
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve build.config.sh / knowledge_store.sh (plane A, script-plane)\n'; return 1; }

  plane_b="$(
    set -e
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve knowledge_store.sh (plane B, bare-env)\n'; return 1; }

  printf '  Plane A (script-plane, via build.config.sh)  = %s\n' "$plane_a"
  printf '  Plane B (bare-env, knowledge_store.sh alone) = %s\n' "$plane_b"

  if [[ "$plane_a" == "$plane_b" ]]; then
    # AGREEMENT IS NOT SUFFICIENT (foundation#1340). The comparison above is an
    # equality check, so it detects a SPLIT root — not a UNIFORMLY WRONG one.
    # With the rung-3 machine conf absent, BOTH planes fall through to
    # _ks_default_root() and agree on a root that is not the store at all; the
    # old code printed a bare OK for exactly that state. That is the same
    # silent-success shape as the 16-day split-brain outage described above,
    # and it is reachable today: nothing in this tree installs, deploys, or
    # verifies the machine conf, so it is an untracked single point of failure.
    #
    # The discriminator is PROVENANCE, not content. Asking "does this look like
    # a store" needs a store-shaped signal, and the only one on hand
    # (`.obsidian/`, which mind_snapshot.sh keys on) is an overlay artifact a
    # kernel-only install does not have. Asking "did anything actually CONFIGURE
    # this root" needs no such signal and is exactly the question whose answer
    # makes agreement meaningful: if the root came from the default fallback,
    # both planes agreeing tells us only that both fell back the same way.
    local provenance root_state
    # `set +eu`, not `set +e`: the ambient shell carries no `-e` (line 24), so
    # relaxing it is inert — `-u` is the inherited option that could actually
    # kill this subshell mid-source. This is the same idiom
    # _ks_machine_conf_root uses for the same "read a sibling config without
    # importing its failures" job.
    #
    # The `-n` test mirrors `ks_root`'s own `:=` semantics, which treat an
    # exported-but-EMPTY KNOWLEDGE_STORE_ROOT as unset — so an empty value
    # labels machine-conf/default-fallback, exactly as ks_root would resolve it.
    #
    # `conf-present-but-unusable` is split out because _ks_machine_conf_root
    # returns 1 for more than one situation: no conf file at all, and a conf
    # that exists but never sets KNOWLEDGE_STORE_ROOT. Both fall back, but only
    # the first is the fresh-install case the remedy text below describes —
    # telling someone who HAS a conf that they have none sends them looking in
    # the wrong place. (Its third return-1 case, a RELATIVE root, never reaches
    # this arm: build.config.sh sources the conf directly, so plane A adopts
    # the relative value while plane B's absolute-path guard rejects it, and
    # the planes MISMATCH above instead — louder and more accurate.)
    provenance="$(
      set +eu
      # shellcheck source=/dev/null
      source "$ks_lib" >/dev/null 2>&1
      if [[ -n "${KNOWLEDGE_STORE_ROOT:-}" ]]; then printf 'env'
      elif _ks_machine_conf_root >/dev/null 2>&1; then printf 'machine-conf'
      elif [[ -f "${KNOWLEDGE_STORE_MACHINE_CONF:-}" ]]; then printf 'conf-present-but-unusable'
      else printf 'default-fallback'; fi
    )"

    if [[ "$provenance" == "env" || "$provenance" == "machine-conf" ]]; then
      printf '  OK — script-plane and bare-env knowledge-store root agree (resolved from %s).\n' "$provenance"
      return 0
    fi

    # `-print -quit` stops at the FIRST hit: this is a cheap "is there anything
    # here at all" probe, not a count, so it must not walk a large store. It is
    # also deliberately NOT `find … | head -1`: `head` closing the pipe early
    # makes find die of SIGPIPE, so that pipeline reports 141 under `pipefail`
    # on the common (a file WAS found) path. Harmless while this script runs
    # `set -uo pipefail` without `-e`, but it would abort the whole check the
    # day someone adds `-e`. `-quit` is POSIX-2024 and present on both BSD
    # (macOS) and GNU find, verified on this box.
    if [[ ! -d "$plane_b" ]]; then
      root_state='the directory does not exist yet'
    elif [[ -n "$(find "$plane_b" -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
      root_state='the directory holds documents'
    else
      root_state='the directory exists but holds no documents'
    fi

    printf '  WARN — both planes agree, but NOTHING CONFIGURED this root: it came\n'
    printf '  from the built-in default fallback, so agreement here proves only that\n'
    printf '  both planes fell back identically — not that the root is your store.\n'
    printf '  Resolved root: %s (%s)\n' "$plane_b" "$root_state"
    printf '  If that is not where your knowledge store lives, every consumer is\n'
    printf '  reading and writing a shadow store — and the plain-files backend\n'
    printf '  creates it on first append, so this fails silently and looks green.\n'
    if [[ "$provenance" == "conf-present-but-unusable" ]]; then
      printf '  Fix: the rung-3 machine conf EXISTS but does not set a usable\n'
      printf '  KNOWLEDGE_STORE_ROOT, so the root fell back silently. Add an\n'
      printf '  absolute KNOWLEDGE_STORE_ROOT to it (a relative value is rejected).\n'
    else
      printf '  Fix: set KNOWLEDGE_STORE_ROOT in the rung-3 machine conf (see\n'
      printf '  docs/config-precedence.md, default path under XDG_CONFIG_HOME or\n'
      printf '  HOME/.config, temperloop/build.config.sh), or point\n'
      printf '  KNOWLEDGE_STORE_MACHINE_CONF at the conf that sets it.\n'
      printf '  (A fresh install with no store configured yet is expected to warn here.)\n'
    fi
    return 0
  fi

  printf '  MISMATCH — a consumer that sources build.config.sh (plane A) resolves\n'
  printf '  KNOWLEDGE_STORE_ROOT to a DIFFERENT directory than a bare consumer that\n'
  printf '  sources only knowledge_store.sh (plane B, e.g. a hook or launchd agent).\n'
  printf '  Fix the rung-3 machine conf (see docs/config-precedence.md, default path\n'
  printf '  under XDG_CONFIG_HOME or HOME/.config, temperloop/build.config.sh) or\n'
  printf '  repoint KNOWLEDGE_STORE_MACHINE_CONF at it so both planes agree.\n'
  return 1
}

# ---------------------------------------------------------------------------
# check_cross_checkout_split — temperloop#777: the CROSS-checkout counterpart
# to check_knowledge_root() above. #774's plane-A/plane-B comparison STAYS —
# it is correct — but it is scoped to THIS checkout ($FOUNDATION): it sources
# build.config.sh / knowledge_store.sh straight from $FOUNDATION, so it can
# never observe a split where ~/.claude itself is bound to a DIFFERENT
# checkout entirely. Live evidence 2026-07-26: after vendoring v0.18.0 into
# ~/dev/foundation, `readlink -f ~/.claude/hooks/session-start-drain.sh`
# resolved into an unrelated checkout — clean-on-main, but still pinned to
# v0.17.0 — whose ks_root() returned the WRONG root, causing 25 drain skips
# in one day. #774's check reported OK in BOTH checkouts the entire time; it
# was never wrong about what it measured, it just wasn't measuring this.
#
# Resolves a REPRESENTATIVE installed surface —
# ~/.claude/hooks/session-start-drain.sh, the exact file the incident above
# traced through (links.sh's own "claude/* -> ~/.claude/*" enumeration
# symlinks the whole claude/hooks/ DIRECTORY, so resolving this one file's
# physical parent dir is enough to reveal which checkout ~/.claude/hooks is
# actually bound to) — to its real (symlink-resolved) physical path, then
# asks git which checkout OWNS that path (`git -C <dir> rev-parse
# --show-toplevel`) and compares it against the checkout doctor itself is
# running in ($FOUNDATION). A mismatch names BOTH paths and BOTH .kernel-pin
# tags, reusing kernel_pin_tag_of() from env-reconcile.sh rather than
# reimplementing the same 8-line file read — sourced in a SUBSHELL only
# (never doctor.sh's own top level), so its globals / arg-parse loop can
# never leak into or fight with doctor.sh's own (mirrors check_knowledge_
# root's own build.config.sh/knowledge_store.sh subshell-sourcing above).
# env-reconcile.sh's own header documents this as safe: its main-enumeration
# body is guarded behind a direct-invocation check (`BASH_SOURCE[0] == $0`)
# that is never true under `source`, so sourcing it only ever defines
# functions and returns — never runs the reconciler or trips one of its
# `exit`s.
#
# Degrades to SKIPPED (never a hard failure) when:
#   - the installed surface doesn't exist yet (a fresh install / stranger's
#     clone that hasn't run `make install-claude` at all);
#   - it exists on disk but doesn't resolve into ANY git checkout (a real,
#     unmanaged/SHADOWED copy rather than a symlink into a checkout —
#     classify_entry's own SHADOWED case already flags that separately, so
#     this check staying silent here does not lose the signal).
#
# Runs fully offline: readlink/pwd -P/git rev-parse do no network I/O.
# ---------------------------------------------------------------------------
_cross_checkout_kernel_pin_tag() {
  local checkout="$1"
  local env_reconcile="${SCRIPT_DIR}/../build/env-reconcile.sh"
  local tag

  if [[ ! -f "$env_reconcile" ]]; then
    printf '(unknown — env-reconcile.sh not found)\n'
    return 0
  fi

  tag="$(
    # NOTE — no apostrophes in these comments: they sit inside a $( ... ) and
    # bash 3.2 (macOS /bin/bash) would read one as an opening quote and swallow
    # the closing paren. Guarded by scripts/lint-bash32-cmdsubst-comment.sh
    # (temperloop#1098).
    #
    # The env-reconcile.sh arg-parse loop reads "$@" — and since this
    # function was itself CALLED with an argument (checkout), that argument
    # is still $1 here, not empty. Left un-cleared, `source` inherits it as
    # the env-reconcile.sh positional params, its arg-parse loop treats
    # the checkout path as an unrecognized flag, and it `exit 2`s before
    # kernel_pin_tag_of is ever defined (silently — the caller only sees an
    # empty, rc!=0 command substitution). Scoped to THIS subshell only, so
    # the enclosing function keeps its own "$@"/"$1" untouched.
    set --
    # shellcheck source=/dev/null
    source "$env_reconcile" 2>/dev/null
    kernel_pin_tag_of "$checkout" 2>/dev/null
  )" || tag=""

  if [[ -n "$tag" ]]; then
    printf '%s\n' "$tag"
  else
    printf '(no .kernel-pin)\n'
  fi
}

check_cross_checkout_split() {
  local home claude_dir surface base
  home="${HOME:-$(eval echo ~)}"
  claude_dir="${home}/.claude"
  surface="${claude_dir}/hooks/session-start-drain.sh"
  base="$(basename "$surface")"

  printf '\nCross-checkout install-source check (temperloop#777):\n'

  if [[ ! -e "$surface" && ! -L "$surface" ]]; then
    printf '  SKIPPED (no installed surface at %s — fresh install, or make install-claude not yet run)\n' "$surface"
    return 0
  fi

  local real_dir real_path
  real_dir="$(cd "$(dirname "$surface")" 2>/dev/null && pwd -P)" || real_dir=""
  if [[ -z "$real_dir" || ! -f "${real_dir}/${base}" ]]; then
    printf '  SKIPPED (%s does not resolve to a real file on disk — broken/dangling install)\n' "$surface"
    return 0
  fi
  real_path="${real_dir}/${base}"

  local installed_root this_root
  installed_root="$(git -C "$real_dir" rev-parse --show-toplevel 2>/dev/null)" || {
    printf '  SKIPPED (%s does not resolve into any git checkout — not a symlink into a kernel repo)\n' "$real_path"
    return 0
  }
  installed_root="$(cd "$installed_root" 2>/dev/null && pwd -P)" || return 0
  this_root="$(cd "$FOUNDATION" 2>/dev/null && pwd -P)" || return 0

  if [[ "$installed_root" == "$this_root" ]]; then
    printf '  OK — installed surface (%s) resolves into THIS checkout (%s).\n' "$real_path" "$this_root"
    return 0
  fi

  local this_tag installed_tag
  this_tag="$(_cross_checkout_kernel_pin_tag "$this_root")"
  installed_tag="$(_cross_checkout_kernel_pin_tag "$installed_root")"

  printf '  MISMATCH — %s\n' "$surface"
  printf '  resolves (real path) to %s\n' "$real_path"
  printf '  which is owned by a DIFFERENT checkout than the one doctor is running from:\n'
  printf '    doctor checkout : %s  [.kernel-pin tag: %s]\n' "$this_root" "$this_tag"
  printf '    installed from  : %s  [.kernel-pin tag: %s]\n' "$installed_root" "$installed_tag"
  printf '  ~/.claude is bound to a DIFFERENT checkout than this one — edits here under\n'
  printf '  claude/hooks/... are NOT what the installed hooks actually run. Re-run\n'
  printf '  "make install-claude" from %s to repoint ~/.claude at THIS checkout,\n' "$this_root"
  printf '  or confirm %s is the intended install source.\n' "$installed_root"
  return 1
}

# ---------------------------------------------------------------------------
# check_cache_state — report the canonical-layer issue-cache store's state
# per board (F#988/#1026): whether a board has opted in (`board.<N>.cache=on`
# in boards.conf) and whether its on-disk store is present/stale/absent.
#
# READ-ONLY and never fails the overall `make doctor` gate — an absent store
# or absent boards.conf is a normal, expected state (cache is opt-in), not a
# drift condition the way a broken managed symlink is. This mirrors
# check_knowledge_root's SKIPPED-is-fine posture for a tree that simply
# doesn't have the pieces wired up yet.
#
# Board discovery is boards.conf-only (the same file board.sh's own
# `_board_conf_file()` would resolve — machine-level, then repo-local),
# never the built-in org-specific case map in board.sh: a stranger's fresh
# clone has no boards.conf and this prints one informational line and
# returns, exactly like links_provision_cache_stores's own discovery.
# ---------------------------------------------------------------------------
check_cache_state() {
  local board_lib="${FOUNDATION}/workflows/scripts/board/lib/board.sh"
  local cache_lib="${FOUNDATION}/workflows/scripts/board/lib/cache.sh"

  printf '\nCache-store state (F#988/#1026):\n'

  if [[ ! -f "$board_lib" || ! -f "$cache_lib" ]]; then
    printf '  SKIPPED (board.sh / cache.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # temperloop#165: the machine conf's subdir renamed foundation/ ->
  # temperloop/ in v0.15.0, and the legacy read was removed in v0.19.0 — the
  # legacy path is no longer a fallback. But this is `doctor`, whose whole
  # job is to explain why a tree isn't wired up the way its operator thinks,
  # so a legacy file that still exists is REPORTED rather than passed over in
  # silence (same disposition as board.sh's own promoted NOTE — and note this
  # fires whether or not a repo-local conf then supplies the boards, since
  # the operator's question is "why is my machine conf being ignored").
  local machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  local machine_conf_legacy="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  local repo_conf="${FOUNDATION}/workflows/scripts/board/boards.conf"
  local conf=""
  if [[ ! -f "$machine_conf" && -f "$machine_conf_legacy" ]]; then
    printf '  NOTE: a machine boards.conf exists only at the legacy path %s — the default moved to %s in v0.15.0 and the legacy read was removed in v0.19.0, so that file is IGNORED; move it.\n' "$machine_conf_legacy" "$machine_conf"
  fi
  if [[ -f "$machine_conf" ]]; then
    conf="$machine_conf"
  elif [[ -f "$repo_conf" ]]; then
    conf="$repo_conf"
  fi

  if [[ -z "$conf" ]]; then
    printf '  (no boards.conf found — nothing configured; cache is OFF everywhere by default)\n'
    return 0
  fi

  local boards
  boards="$(grep -oE '^board\.[0-9]+\.repo=' "$conf" 2>/dev/null | cut -d. -f2 | sort -un)"
  if [[ -z "$boards" ]]; then
    printf '  (%s declares no board with a repo= axis — nothing to report)\n' "$conf"
    return 0
  fi

  local n enabled state
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    if grep -q "^board\.${n}\.cache=on$" "$conf" 2>/dev/null; then
      enabled="on"
    else
      enabled="off"
    fi

    state="$(
      # shellcheck source=/dev/null
      source "$board_lib" 2>/dev/null
      # shellcheck source=/dev/null
      source "$cache_lib" 2>/dev/null
      repo="$(board_repo "$n" 2>/dev/null)" || { printf 'n/a (no repo axis)'; exit 0; }
      meta="$(cache_meta_file "$repo" 2>/dev/null)"
      if [[ -z "$meta" || ! -f "$meta" ]]; then
        printf 'absent'
      elif cache_stale "$repo" 2>/dev/null; then
        printf 'stale'
      else
        printf 'present'
      fi
    )"

    printf '  board.%-3s  cache=%-3s  store=%s\n' "$n" "$enabled" "$state"
  done <<<"$boards"
}

# ---------------------------------------------------------------------------
# check_bm_tool_install — install AND REPORT the knowledge_search backend's
# pinned basic-memory uv tool (temperloop#1113).
#
# This is the DOCTOR half of the ratified hybrid install design. The other
# half lives in workflows/scripts/lib/knowledge_search.sh's availability gate,
# which lazily installs the pin on first use so a stranger who never runs
# doctor still gets a working first `ks_search`. Neither half replaces the
# other: the lazy half keeps the zero-setup first-run virtue that made `uvx`
# the original default, and this half gives an INSTALLED checkout a
# predictable, pre-warmed state — so the first real search is fast, and an
# operator can see the pin's install state without running a search at all.
#
# Why the switch happened (the state this reports on): resolving
# `uvx --from basic-memory==<pin>` per run left uv unpacking a fresh
# environment into its own cache with no permanent install location and no
# expiry — measured at 30 GB against a 273 MB store, unprunable for as long as
# a warm daemon held the cache lock. An installed uv tool puts a stable
# virtualenv on disk instead, and the cache goes back to being a cache.
#
# ADVISORY, never a gate. `make doctor` must stay runnable on a host with no
# `uv`, no network, or no interest in the search seam at all — an uninstalled
# or uninstallable pin is a reported state, not a broken managed link. It
# therefore always returns 0, exactly like check_cache_state.
#
# Runs entirely inside a SUBSHELL so sourcing the two libraries cannot leak
# their `:=` defaults (KNOWLEDGE_STORE_ROOT and friends) into doctor's own
# scope or into any later check — the same isolation posture
# check_knowledge_root and check_cache_state already use.
# ---------------------------------------------------------------------------
check_bm_tool_install() {
  local store_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"
  local search_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_search.sh"
  # The install bound (KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT) is applied by
  # _ks_bm_install_tool ONLY when run_with_timeout is already in scope — it is
  # the caller's job to provide it. Doctor is the caller that most predictably
  # drives the install (it runs it unconditionally on an absent/drifted pin),
  # and this check is documented as advisory, never a gate: `make doctor` must
  # stay runnable on a host with no uv and no network. Without this source the
  # setting is inert here and a wedged network turns `make doctor` into an
  # unbounded hang — worse than the failure the advisory posture was built for.
  local timeout_lib="${FOUNDATION}/workflows/scripts/lib/portable-timeout.sh"

  printf '\nknowledge_search basic-memory tool (temperloop#1113):\n'

  if [[ ! -f "$store_lib" || ! -f "$search_lib" ]]; then
    printf '  SKIPPED (knowledge_store.sh / knowledge_search.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  (
    # shellcheck source=/dev/null
    source "$store_lib" 2>/dev/null || {
      printf '  SKIPPED (could not source knowledge_store.sh)\n'; exit 0; }
    # shellcheck source=/dev/null
    source "$search_lib" 2>/dev/null || {
      printf '  SKIPPED (could not source knowledge_search.sh)\n'; exit 0; }
    # Best-effort: an older/vendored tree without this lib simply runs the
    # install unbounded, exactly as it did before this source existed.
    if [ -f "$timeout_lib" ]; then
      # shellcheck source=/dev/null
      source "$timeout_lib" 2>/dev/null || true
    fi

    # A kernel checkout older than #1113 has no install seam to drive. Report
    # that plainly rather than failing — this file is also read by vendored
    # trees that pull the kernel forward at their own pace.
    if ! declare -F _ks_bm_ensure_tool >/dev/null 2>&1; then
      printf '  SKIPPED (this knowledge_search.sh predates the uv-tool install seam)\n'
      exit 0
    fi

    printf '  pin         %s\n' "$(_ks_bm_pin_id)"
    printf '  entry point %s\n' "$(_ks_bm_bin_path)"

    if _ks_bm_tool_ready; then
      printf '  state       INSTALLED (matches the configured pin)\n'
      exit 0
    fi

    if ! command -v uv >/dev/null 2>&1; then
      printf '  state       UNAVAILABLE (uv is not on PATH — install uv, then re-run doctor)\n'
      exit 0
    fi

    if [ -x "$(_ks_bm_bin_path)" ]; then
      printf '  state       PIN DRIFT (installed at a different pin) — re-installing\n'
    else
      printf '  state       ABSENT — installing\n'
    fi

    if _ks_bm_ensure_tool; then
      printf '  state       INSTALLED (matches the configured pin)\n'
    else
      printf '  state       INSTALL FAILED (uv output above) — ks_search will degrade with a "skipped --" notice\n'
    fi
  )
  return 0
}

# ---------------------------------------------------------------------------
# check_reviewer_coverage — advisory, WARN-level reviewer-activation-coverage
# check (temperloop#550, ADR 0007/0008). REUSES #548's pure, non-interactive
# data path (reviewer_coverage_gaps / reviewer_coverage_check_integrity,
# sourced from reviewer-activation-coverage.sh) — NEVER #549's interactive
# reviewer-activate.sh (that script has no source-guard and would run its
# whole offer/prompt body unconditionally if sourced here).
#
# Strictly advisory: a WARN increments a local tally ONLY, never `non_ok`/
# the exit code — an inert, un-activated reviewer is the DESIGNED default
# (opt-in, ADR 0007), so a fresh checkout with zero activated reviewers must
# still exit 0. Mirrors check_cache_state()'s read-only `|| true` posture.
#
# Three outcomes per catalogued-reviewer language, computed from #548's own
# gap-set semantics:
#   - resolvable gap (catalogued in reviewer-routing.tsv, material usage at/
#     above REVIEWER_SCAN_MIN_FILES, not yet activated, not durably declined)
#     -> WARN, every run, until activated or declined. reviewer_coverage_
#     gaps() already computes exactly this set.
#   - durably declined (a decline marker under the per-repo reviewer-state
#     dir, #549's format) -> silent. reviewer_coverage_gaps() already
#     excludes these from its output, so nothing extra is needed here.
#   - uncatalogued (a reviewer-routing.tsv row whose catalog-agent-path does
#     NOT resolve to a real file on disk — reviewer_coverage_check_
#     integrity() reports it DANGLING, i.e. that "catalogued" language has no
#     actual backing rubric to activate) -> a ONE-TIME INFO, never a
#     repeating WARN. This check is catalog-wide (not dependent on this
#     checkout's own file mix), so it fires identically anywhere the tsv/
#     catalog pairing is broken. "One-time" state is a small marker file
#     under the SAME gitignored per-repo reviewer-state dir #549 owns
#     (.claude/reviewer-state/doctor-uncatalogued-notified) — this is
#     doctor.sh's FIRST write-capable check, a deliberate scoped exception to
#     its otherwise read-only posture, confined to that one gitignored path
#     and NEVER touching anything a `git add -A` would stage. If the state
#     dir/gitignore can't be confirmed safe, this degrades to read-only
#     (skips the write, so the INFO simply reprints next run) rather than
#     leaking state anywhere — and never fails the check either way.
# ---------------------------------------------------------------------------
check_reviewer_coverage() {
  local rac_sh="${FOUNDATION}/workflows/scripts/install/reviewer-activation-coverage.sh"

  printf '\nReviewer coverage check (temperloop#550):\n'

  if [[ ! -f "$rac_sh" ]]; then
    printf '  SKIPPED (reviewer-activation-coverage.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=/dev/null
  if ! source "$rac_sh" 2>/dev/null; then
    printf '  SKIPPED (could not source reviewer-activation-coverage.sh)\n'
    return 0
  fi

  if [[ ! -f "${REVIEWER_ROUTING_TSV:-}" ]]; then
    printf '  SKIPPED (reviewer-routing.tsv not found at %s)\n' "${REVIEWER_ROUTING_TSV:-<unset>}"
    return 0
  fi

  local project_dir="$FOUNDATION"
  local gaps=""
  gaps="$(reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV" 2>/dev/null)" || gaps=""

  local warn_count=0 name
  if [[ -n "$gaps" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      printf '  WARN  %-22s catalogued, not yet activated (repo has material usage at/above threshold) — run reviewer-activate.sh to opt in or decline\n' "$name"
      warn_count=$((warn_count + 1))
    done <<<"$gaps"
  fi

  local integrity_err=""
  integrity_err="$(reviewer_coverage_check_integrity "$REVIEWER_ROUTING_TSV" "$FOUNDATION" 2>&1 1>/dev/null)" || true

  if [[ -n "$integrity_err" ]]; then
    local state_dir="${project_dir}/.claude/reviewer-state"
    local notice_marker="${state_dir}/doctor-uncatalogued-notified"

    if [[ ! -e "$notice_marker" ]]; then
      printf '  INFO  one or more reviewer-routing.tsv entries reference a language with no backing rubric on disk (uncatalogued) — see docs/features/review-agents.md for the bring-your-own path:\n'
      printf '%s\n' "$integrity_err" | sed 's/^/        /'

      if gitignore_ensure_entry "$project_dir" ".claude/reviewer-state/" "${project_dir}/.claude/reviewer-state/.doctor-probe"; then
        # if-then-else, not `A && B || C` (SC2015): the marker write is
        # best-effort — a failed mkdir or printf must never fail the check.
        if mkdir -p "$state_dir" 2>/dev/null; then
          printf '# doctor.sh: uncatalogued-language notice already shown on %s\n' "$(date +%Y-%m-%d)" >"$notice_marker" 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [[ "$warn_count" -eq 0 && -z "$integrity_err" ]]; then
    printf '  no resolvable reviewer-activation gaps\n'
  fi

  return 0
}

# ---------------------------------------------------------------------------
# check_legacy_host_config — HOST-STATE preflight for legacy host-config
# paths a release has REMOVED (temperloop#908). Delegates entirely to the
# registry-driven workflows/scripts/install/legacy-host-preflight.sh (see
# that file's own header for the full rationale and the two instances that
# motivated it — foundation#1419's stranded funnel-cron.plist and
# temperloop#165's unmigrated legacy boards.conf).
#
# Unlike check_cache_state's advisory NOTE (which never affects doctor's
# exit code — a legacy machine conf that's merely unread might still be
# harmless if a repo-local conf covers the same boards), this check is a
# GATE: a registry entry that comes back LIVE-UNMIGRATED means a host
# consumable a release removed is both still present AND has no successor
# in place, which is never a benign state — it is the exact silent-and-
# wrong failure both motivating instances produced. Non-zero here fails
# `make doctor`, and therefore fails the `temperloop update` post-checkout
# doctor run (bin/subcommands/update.sh run_post_checkout()) — the point a
# release actually lands on an operator's host.
#
# Degrades to SKIPPED (never a hard failure) when legacy-host-preflight.sh
# itself is absent — a stranger's fresh clone at a kernel version that
# predates this check, or a vendored tree that hasn't pulled this far yet.
# ---------------------------------------------------------------------------
check_legacy_host_config() {
  local preflight_sh="${FOUNDATION}/workflows/scripts/install/legacy-host-preflight.sh"

  printf '\nLegacy host-config preflight (temperloop#908):\n'

  if [[ ! -f "$preflight_sh" ]]; then
    printf '  SKIPPED (legacy-host-preflight.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=legacy-host-preflight.sh
  if ! source "$preflight_sh" 2>/dev/null; then
    printf '  SKIPPED (could not source legacy-host-preflight.sh)\n'
    return 0
  fi

  if ! legacy_host_preflight_run; then
    printf '  one or more legacy host-config paths are LIVE and UNMIGRATED — see above.\n'
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main — enumerate and classify every managed entry.
# ---------------------------------------------------------------------------
ok=0
non_ok=0
non_ok_entries=()

printf '\nmake doctor — managed link status (%s)\n\n' "$FOUNDATION"
printf '  %-10s  %s\n' "STATUS" "TARGET"
printf '  %-10s  %s\n' "----------" "------"

while IFS=$'\t' read -r target kind expected_src; do
  status="$(classify_entry "$target" "$expected_src" "$kind")"
  printf '  %-10s  %s\n' "$status" "$target"
  if [[ "$status" == "OK" ]]; then
    (( ok++ )) || true
  else
    (( non_ok++ )) || true
    non_ok_entries+=("${status}  ${target}")
  fi
done < <(links_enumerate "$FOUNDATION")

echo
printf 'OK: %d   Non-OK: %d\n' "$ok" "$non_ok"

knowledge_root_status=0
check_knowledge_root || knowledge_root_status=$?

cross_checkout_status=0
check_cross_checkout_split || cross_checkout_status=$?

check_cache_state || true

check_bm_tool_install || true

check_reviewer_coverage || true

legacy_host_status=0
check_legacy_host_config || legacy_host_status=$?

if (( non_ok > 0 )); then
  echo
  echo "Non-OK entries:"
  printf '  %s\n' "${non_ok_entries[@]}"
fi

if (( non_ok > 0 || knowledge_root_status != 0 || cross_checkout_status != 0 || legacy_host_status != 0 )); then
  echo
  exit 1
fi

echo
