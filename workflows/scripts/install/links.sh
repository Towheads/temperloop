#!/usr/bin/env bash
# Shared link enumeration and apply helper for make install-* and make doctor.
#
# SINGLE SOURCE OF TRUTH for every managed symlink (and the one managed real
# file) that the install-* targets create.  Both the apply side (install-*) and
# the verify side (make doctor) source this file to obtain the same enumeration
# — changing it changes both, so apply and verify can never drift.
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/links.sh"
#   links_enumerate                     # emits one record per managed path
#   links_apply_symlink <target> <src>  # idempotent apply (for kind=symlink)
#   links_provision_cache_stores [<foundation-root>]  # cache-store root
#                                        # provisioning (F#988/#1026) — see
#                                        # that function's own header below
#   links_persist_knowledge_root [<foundation-root>]  # knowledge-store root
#                                        # persist/verify (F#1771) — see that
#                                        # function's own header below
#
# Output of links_enumerate — one record per line, 3 tab-separated fields:
#
#   <target>  <kind>  <expected_source>
#
#   target          absolute path that should exist after install
#   kind            symlink | real | gh-shim
#   expected_source absolute source path a symlink should point at
#                   (empty for kind=real and kind=gh-shim)
#
# NOTE: kind is the SECOND field (not third) so that expected_source, which
# can be empty for kind=real and kind=gh-shim, falls at the END of the line.
# Shell `read` with IFS=tab collapses consecutive tab chars (treating `\t\t`
# as a single delimiter), so an empty middle field would be silently lost.
# With kind in field 2 and expected_source trailing, `read -r target kind src`
# reads correctly even when src is empty.
#
# kind=real       — settings.json (#292): generated as a real file by
#                   install-settings.sh, not a symlink.  Doctor: OK iff a
#                   plain (non-symlink) file exists.
# kind=gh-shim    — ~/.local/bin/gh: a banner-stamped real copy recognised by
#                   a 'call-logger' marker.  Doctor: OK iff the file exists,
#                   is NOT a symlink, and contains the marker.
#
# Callers MUST set FOUNDATION to the repo root before sourcing, or pass it as
# an argument to links_enumerate:
#
#   links_enumerate [<foundation-root>]
#
# If omitted, FOUNDATION must already be in the environment.
#
# shellcheck shell=bash

# Guard against double-sourcing.
if [[ "${_FOUNDATION_LINKS_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_FOUNDATION_LINKS_SH_LOADED=1

# ---------------------------------------------------------------------------
# links_enumerate [<foundation-root>]
#
# Emits one tab-delimited record per managed path to stdout.  Safe to pipe or
# read into an array; produces no side-effects.
#
# Output format (3 tab-separated fields):  target \t kind \t expected_source
# expected_source is empty for kind=real and kind=gh-shim (trailing empty is
# safe with shell `read`; empty middle field is not, hence kind in field 2).
# ---------------------------------------------------------------------------
links_enumerate() {
  local foundation="${1:-${FOUNDATION:-}}"
  if [[ -z "$foundation" ]]; then
    echo "links_enumerate: FOUNDATION is not set" >&2
    return 1
  fi

  local home="${HOME:-$(eval echo ~)}"
  local claude_dir="${home}/.claude"
  local local_bin="${home}/.local/bin"
  local board_src="${foundation}/workflows/scripts/board"

  # ---- 1. env/ dotfiles -> ~ -------------------------------------------------
  # Mirrors install-env: loops env/.* (excluding . .. .gitkeep). Guarded on
  # the directory actually existing: a kernel-only checkout (this repo,
  # temperloop) has NO env/ at all — env/* is overlay-only, composed in only
  # by a downstream overlay checkout. Without this guard, an absent env/
  # leaves the glob unexpanded
  # (bash's default non-nullglob behavior), so `for f in .../env/.*` iterates
  # ONCE with the literal pattern string itself — basename of that is ".*",
  # which is neither "." nor ".." nor ".gitkeep", so it fell through and
  # emitted a bogus `${home}/.*` record (temperloop#264, caught by
  # `temperloop install`/doctor.sh going green on a kernel-only checkout).
  local f name target src
  if [[ -d "${foundation}/env" ]]; then
    for f in "${foundation}"/env/.*; do
      name="$(basename "$f")"
      [[ "$name" == "." || "$name" == ".." || "$name" == ".gitkeep" ]] && continue
      target="${home}/${name}"
      src="${foundation}/env/${name}"
      printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
    done
  fi

  # ---- 2. claude/* entries -> ~/.claude/ ------------------------------------
  # Mirrors install-claude: loops claude/*.
  # Exception: settings.json is a managed real file (kind=real, no src).
  # Exception: CLAUDE.kernel.md / CLAUDE.overlay.md are COMPOSE SOURCES for
  # the generated ~/.claude/CLAUDE.md (kind=claude-md, emitted once below,
  # not per-source-file) — not deployed under their own names (foundation
  # Epic B "layered CLAUDE.md").
  for f in "${foundation}"/claude/*; do
    name="$(basename "$f")"
    [[ "$name" == ".gitkeep" ]] && continue
    case "$name" in
      CLAUDE.kernel.md|CLAUDE.overlay.md) continue ;;
    esac
    target="${claude_dir}/${name}"
    if [[ "$name" == "settings.json" ]]; then
      # #292: generated as a real file by install-settings.sh, not a symlink.
      # Trailing tab keeps field count at 3 (expected_source is empty for real).
      printf '%s\t%s\t\n' "$target" "real"
    else
      src="${foundation}/claude/${name}"
      printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
    fi
  done

  # ---- 2b. composed CLAUDE.md (kernel + overlay + rendered knowledge-store
  # routing) -> ~/.claude/CLAUDE.md ------------------------------------------
  # Generated real file (kind=claude-md, doctor/install treat it like
  # kind=real) via workflows/scripts/install-claude-md.sh — a symlink can't
  # compose two source files. Only emitted when both sources exist, so a
  # fixture/older tree without the split simply gets no entry here.
  if [[ -f "${foundation}/claude/CLAUDE.kernel.md" && -f "${foundation}/claude/CLAUDE.overlay.md" ]]; then
    printf '%s\t%s\t\n' "${claude_dir}/CLAUDE.md" "claude-md"
  fi

  # ---- 3. board toolkit commands -> ~/.local/bin ----------------------------
  # Mirrors install-board: BOARD_CMDS = claim release worklist reconcile capture
  # milestone pr-enqueue. pr-enqueue (#534) is a dev-process PR/merge-queue
  # helper co-deployed through the same PATH machinery (its source lives under
  # board/, so install-board's "src under BOARD_SRC" filter installs it).
  local cmd
  for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
    target="${local_bin}/${cmd}"
    src="${board_src}/${cmd}.sh"
    printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
  done

  # ---- 4. gh call-logger shim -> ~/.local/bin/gh ----------------------------
  # Mirrors install-gh-logger: a managed REAL (banner-stamped) copy, not a symlink.
  # doctor checks for the 'call-logger' marker to identify it as our shim.
  # Trailing tab keeps field count at 3 (expected_source is empty for gh-shim).
  target="${local_bin}/gh"
  printf '%s\t%s\t\n' "$target" "gh-shim"
}

# ---------------------------------------------------------------------------
# links_apply_symlink <target> <expected_source>
#
# Idempotent symlink creation with the canonical install-* semantics:
#   - already correctly linked   -> print "✓ <name> already linked"
#   - a symlink pointing anywhere else (including a DANGLING one into a
#     deleted worktree) -> atomically re-point it, print "→ relinked <name>".
#     This is what makes a re-run self-healing: a farm of stale/dangling links
#     is repaired in place rather than failing with "ln: <target>: File exists".
#   - a real (non-symlink) file/dir at the target -> print "! <name> exists
#     and is not a symlink — skipping (backup manually)". A user's real file is
#     never clobbered.
#   - absent -> create symlink, print "→ linked <name>"
#
# The heal path uses `ln -sfn` (force + no-dereference): `-f` removes the
# existing symlink before creating the new one, and `-n` ensures an old symlink
# that resolves to a directory is replaced itself rather than the new link
# landing *inside* it. This satisfies the acceptance's "ln -sfn or rm-then-ln"
# atomic-replace requirement. Critically, `[ -L ]` is tested BEFORE `[ -e ]`
# because a dangling symlink is `-L`-true but `-e`-false, so the old `-e`-first
# check silently missed it and fell through to a bare `ln -s` (the "File
# exists" failure this fixes).
#
# Used by install-env, install-claude, and install-board recipes that have been
# refactored to source this helper.
#
# Callers are responsible for mkdir -p on the parent directory of <target>
# before calling this function.
# ---------------------------------------------------------------------------
links_apply_symlink() {
  local target="$1"
  local src="$2"
  local name
  name="$(basename "$target")"

  if [ -L "$target" ]; then
    # It IS a symlink (possibly dangling — `-L` is true even when the link is
    # broken). Either it already points where we want, or it's stale/dangling
    # and we heal it in place.
    if [ "$(readlink "$target")" = "$src" ]; then
      echo "  ✓ ${name} already linked"
    else
      ln -sfn "$src" "$target" && echo "  → relinked ${name}"
    fi
  elif [ -e "$target" ]; then
    echo "  ! ${name} exists and is not a symlink — skipping (backup manually)"
  else
    ln -s "$src" "$target" && echo "  → linked ${name}"
  fi
}

# ---------------------------------------------------------------------------
# links_provision_cache_stores [<foundation-root>]
#
# Install-time provisioning for the canonical-layer issue-cache store
# (F#988/#1026, workflows/scripts/board/lib/cache.sh + CACHE-STORE.md):
#
#   1. Creates the cache store ROOT directory (idempotent — a plain mkdir -p),
#      so a later `cache_read`/`cache_refresh` never races an absent parent
#      and `make doctor` has a directory to classify instead of "absent" on
#      a machine that has never run a single cache read yet. Per-repo store
#      sub-directories (`.../issues/<owner>-<repo>/`) are DELIBERATELY left
#      to cache.sh's own lazy `mkdir -p` on first real refresh — this
#      function only owns the shared root, not per-board provisioning.
#   2. For every board boards.conf declares a `repo` axis for but has NO
#      `cache=` line yet, prints a one-line opt-in hint naming the exact
#      line to add. NEVER writes/edits boards.conf itself — same
#      human-owned-conf-file discipline board_backend's `backend=issues`
#      axis already established (boards.conf.example's own header: "This
#      file is parsed with grep/cut only — never sourced or eval'd").
#
# Discovery is a deliberately REDUCED, two-rung subset of board.sh's
# `_board_conf_file()` order — the two default paths only, as literals, via
# grep/cut, so links.sh sources nothing at install time and stays
# dependency-free. In order: machine-level
# $XDG_CONFIG_HOME/temperloop/boards.conf, then the repo-local
# workflows/scripts/board/boards.conf next to board.sh.
#
# What it does NOT mirror (this function is hint-only, so a conf it misses
# costs a suggestion, never a wrong action):
#   * the $BOARDS_CONF_MACHINE / $BOARDS_CONF_REPO_LOCAL env overrides — an
#     operator who redirects either one gets no hint from here, though
#     board.sh itself still honors them at runtime;
#   * the #494 composed-tree consumer-root rung `_board_consumer_root_conf()`
#     probes between the two rungs above.
# Keep this list current if `_board_conf_file()` grows a rung.
# If neither conf exists, this only creates the store root
# and prints one informational line — never fails (a bare `mkdir -p` on a
# writable path does not fail; a caller on a read-only HOME sees one stderr
# notice and a non-zero return, same idiom as links_apply_symlink's siblings).
#
# Safe to call from any install recipe (foundation's `install-board`, a
# future kernel-standalone target, or directly) — no gh calls, no network,
# purely local filesystem + conf-file reads.
# ---------------------------------------------------------------------------
links_provision_cache_stores() {
  local foundation="${1:-${FOUNDATION:-}}"
  local store_root="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"

  if ! mkdir -p "$store_root" 2>/dev/null; then
    echo "  ! could not create cache store root: ${store_root} (permissions?)" >&2
    return 1
  fi
  echo "  ✓ cache store root ready: ${store_root}"

  # The temperloop#165 legacy $XDG_CONFIG_HOME/foundation/ fallback was
  # removed in v0.19.0 — that path is no longer read. A stale file still
  # sitting there is REPORTED by name rather than passed over in silence,
  # matching board.sh's own promoted NOTE and doctor.sh's check_cache_state.
  # Silence is not safe here: this function's no-conf arm prints "(no
  # boards.conf found — nothing to suggest)", which is FALSE for an operator
  # whose only conf is at the legacy path, and points them nowhere. The
  # installer is a distinct surface from doctor — `temperloop install`
  # (bin/subcommands/install.sh) calls this function and never invokes
  # doctor.sh, it only SUGGESTS running it — so naming the file here cannot
  # double-print with doctor's diagnostic in one run.
  local machine_conf machine_conf_legacy conf=""
  machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  machine_conf_legacy="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  if [ ! -f "$machine_conf" ] && [ -f "$machine_conf_legacy" ]; then
    echo "  NOTE: a machine boards.conf exists only at the legacy path ${machine_conf_legacy} — the default moved to ${machine_conf} in v0.15.0 and the legacy read was removed in v0.19.0, so that file is IGNORED; move it."
  fi
  if [ -f "$machine_conf" ]; then
    conf="$machine_conf"
  elif [ -n "$foundation" ] && [ -f "${foundation}/workflows/scripts/board/boards.conf" ]; then
    conf="${foundation}/workflows/scripts/board/boards.conf"
  fi

  if [ -z "$conf" ]; then
    echo "  (no boards.conf found — nothing to suggest; cache stays off everywhere until one exists)"
    return 0
  fi

  local boards n
  boards="$(grep -oE '^board\.[0-9]+\.repo=' "$conf" 2>/dev/null | cut -d. -f2 | sort -un)"
  if [ -z "$boards" ]; then
    echo "  (${conf} declares no board with a repo= axis — nothing to suggest)"
    return 0
  fi

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if grep -q "^board\.${n}\.cache=" "$conf" 2>/dev/null; then
      continue   # already has an explicit cache= line either way — nothing to suggest
    fi
    echo "  → board ${n} has no cache axis yet — add this line to $(basename "$conf") to opt in: board.${n}.cache=on"
  done <<<"$boards"
}

# ---------------------------------------------------------------------------
# links_persist_knowledge_root [<foundation-root>]
#
# Install-time PERSIST/VERIFY for the knowledge-store root (foundation#1771,
# the install half of the detection half foundation#1340 already shipped in
# doctor.sh's check_knowledge_root).
#
# THE DEFECT. ks_root() (workflows/scripts/lib/knowledge_store.sh) resolves
#   KNOWLEDGE_STORE_ROOT env -> _ks_machine_conf_root() -> _ks_default_root()
# and the middle rung reads the rung-3 machine conf named by
# KNOWLEDGE_STORE_MACHINE_CONF. Until now NOTHING in this tree wrote, installed,
# or verified that file: it was untracked and operator-created, so losing it
# dropped every consumer onto the XDG default — and because the plain-files
# backend's append does `mkdir -p`, the wrong root is silently CREATED and
# written to rather than erroring. That is a single point of failure with no
# owner. This function gives it one: the install path.
#
# THE HARD CONSTRAINT: NEVER GUESS A ROOT. A stranger installing this kernel
# with no knowledge store must not be blocked, and must not have a store
# location invented for them. So this function only ever persists a value the
# OPERATOR already supplied (KNOWLEDGE_STORE_ROOT in the install-time
# environment); with nothing supplied it reports and returns, writing nothing.
# That is why this WRITES a conf where links_provision_cache_stores only ever
# HINTS at one: boards.conf would need a policy decision this code cannot make,
# whereas here there is no decision to make — the value is already the
# operator's own, and all that is missing is durability.
#
# Four behaviors, in order:
#   1. NEVER CLOBBER. A conf that already yields a usable absolute root (i.e.
#      _ks_machine_conf_root succeeds) is left byte-identical. This is also
#      what makes a second `temperloop install` a no-op: run one persists,
#      run two takes this arm.
#   2. PERSIST, DON'T INVENT. With no usable conf root but an absolute
#      KNOWLEDGE_STORE_ROOT in the environment, append
#      `: "${KNOWLEDGE_STORE_ROOT:=<value>}"` to the conf (creating the file
#      and its parent when absent). The `:=` idiom is REQUIRED of every rung-3
#      conf line (build.config.sh's own layer-3 header) so an exported env var
#      still outranks it.
#   3. ABSOLUTE ROOTS ONLY. _ks_machine_conf_root rejects a relative root, so
#      persisting one would produce a conf that STILL resolves by
#      default-fallback — a silent no-op dressed up as a fix. A relative value
#      is refused by name instead.
#   4. VERIFY, DON'T SILENTLY PROCEED. With nothing configuring the root at
#      all, print the default-fallback notice — reusing the provenance
#      vocabulary check_knowledge_root already established (`env` /
#      `machine-conf` / `conf-present-but-unusable` / `default-fallback`), so
#      the installer and doctor name the same state the same way. NEVER fatal:
#      a fresh install legitimately has no store yet.
#
# THE ONE CASE IT REFUSES TO REPAIR: a conf that MENTIONS KNOWLEDGE_STORE_ROOT
# yet yields no usable root (an empty or relative value). Appending a `:=` line
# after an existing relative assignment is dead text — the var is already
# bound, so the new line never fires — and rewriting the operator's own line is
# a clobber. Both are refused with the line named, for a human to fix.
#
# PROVENANCE IS DERIVED FROM THE SHIPPED LIB, NOT RE-IMPLEMENTED: the conf PATH
# and the "is it usable" verdict both come from sourcing knowledge_store.sh in
# an isolated subshell and calling its own _ks_machine_conf_root — the same
# `set +eu` read-a-sibling-config-without-importing-its-failures idiom
# check_knowledge_root and _ks_machine_conf_root already use. No second copy of
# the path literal or the guard lives here.
#
# NOT MANIFEST-MANAGED, deliberately — the same call this function's sibling
# links_provision_cache_stores makes for the cache store (uninstall.sh scope
# (d)). The rung-3 machine conf is OPERATOR CONFIG that outlives any one
# install: it commonly carries many other settings, and the one line this
# function may append records where the operator's own knowledge store lives.
# "Restore it" and "remove it" are the wrong verbs for it, so `temperloop
# uninstall` never touches it, exactly as it never touches the store itself.
#
# Never fails the install: every arm returns 0 except an unwritable conf path
# (one stderr notice + return 1), matching links_provision_cache_stores. No
# network, no gh calls, purely local filesystem.
# ---------------------------------------------------------------------------
links_persist_knowledge_root() {
  local foundation="${1:-${FOUNDATION:-}}"
  local ks_lib="${foundation}/workflows/scripts/lib/knowledge_store.sh"

  if [ -z "$foundation" ] || [ ! -f "$ks_lib" ]; then
    echo "  SKIPPED (knowledge_store.sh not found under '${foundation}')"
    return 0
  fi

  # Both reads run in an isolated subshell (`set +eu`, output silenced) so the
  # lib's own `:=` defaults never leak into the caller's environment. An
  # already-exported KNOWLEDGE_STORE_MACHINE_CONF (the documented test seam)
  # is honored because the lib's own `:=` leaves it alone.
  local conf conf_root
  conf="$(
    set +eu
    # shellcheck source=/dev/null
    . "$ks_lib" >/dev/null 2>&1
    printf '%s' "${KNOWLEDGE_STORE_MACHINE_CONF}"
  )"
  # `unset KNOWLEDGE_STORE_ROOT` FIRST, and it is load-bearing: the conf is a
  # rung-3 file whose every line uses the assign-if-unset idiom, so with an
  # exported KNOWLEDGE_STORE_ROOT in scope the conf's own assignment is a
  # no-op and _ks_machine_conf_root hands back the ENV value — which would
  # make this function report the env root as though the conf held it, and
  # would hide a conf/env divergence instead of surfacing it. The question
  # asked here is strictly "does the CONF itself yield a usable absolute
  # root", which is exactly the question the never-clobber rule turns on.
  conf_root="$(
    set +eu
    unset KNOWLEDGE_STORE_ROOT
    # shellcheck source=/dev/null
    . "$ks_lib" >/dev/null 2>&1
    _ks_machine_conf_root 2>/dev/null
  )"

  # An unparseable ks_lib leaves KNOWLEDGE_STORE_MACHINE_CONF unset under
  # `set +u`, so conf="" flows on: `dirname ""` is `.`, `mkdir -p .` SUCCEEDS,
  # and the run dies at `>""` reporting a permissions problem for an empty
  # path — a wrong diagnosis that costs the operator a wasted hunt.
  if [ -z "$conf" ]; then
    echo "  SKIPPED (could not resolve KNOWLEDGE_STORE_MACHINE_CONF from ${ks_lib})"
    return 0
  fi

  # ---- 1. Never clobber ---------------------------------------------------
  if [ -n "$conf_root" ]; then
    # "conf provenance", not "provenance": with KNOWLEDGE_STORE_ROOT exported
    # doctor's ordered discriminator reports `env` for the RESOLVED root, so an
    # unqualified `provenance: machine-conf` here would contradict it. This
    # line reports where the CONF stands; the NOTE below covers divergence.
    echo "  = knowledge-store root already persisted (conf provenance: machine-conf): ${conf_root}"
    echo "    conf: ${conf} (left untouched)"
    if [ -n "${KNOWLEDGE_STORE_ROOT:-}" ] && [ "${KNOWLEDGE_STORE_ROOT}" != "$conf_root" ]; then
      echo "  NOTE: KNOWLEDGE_STORE_ROOT is set in this environment to ${KNOWLEDGE_STORE_ROOT}, which DIFFERS from the persisted root above. The conf wins for every process that does not inherit that export; nothing was rewritten (never clobber). Reconcile by hand if the env value is the one you meant to keep."
    fi
    return 0
  fi

  # ---- 2/3. Persist an operator-supplied absolute root --------------------
  local env_root="${KNOWLEDGE_STORE_ROOT:-}"
  if [ -n "$env_root" ]; then
    case "$env_root" in
      /*) ;;
      *)
        echo "  ! knowledge-store root NOT persisted: KNOWLEDGE_STORE_ROOT is set to a RELATIVE path (${env_root})." >&2
        echo "    ks_root()'s machine-conf rung rejects a relative root, so persisting it would leave every consumer on the default fallback anyway. Re-run with an absolute path." >&2
        return 0
        ;;
    esac

    # The persisted line is `: "${KNOWLEDGE_STORE_ROOT:=<root>}"` — the value
    # sits inside DOUBLE quotes, so a `$`, a backtick or a backslash in the
    # path is not data when the conf is re-sourced: it EXPANDS. A root of
    # `/tmp/store$HOME-literal` persists verbatim and then resolves to
    # `/tmp/store/Users/you/home-literal` — a conf that READS correct while
    # every consumer silently uses a different directory. That is the exact
    # silent-wrong-root class this whole issue exists to close, reintroduced
    # by the fix for it. (Measured: the round-trip returned the expanded path.)
    #
    # Refuse rather than escape, matching the relative-path branch above. A
    # single-quoted assignment would carry these safely but would depart from
    # the `:=` idiom every other line in this conf uses, and a shell
    # metacharacter in a knowledge-store path is pathological enough that
    # saying so plainly beats quietly rewriting the operator's path.
    # NOTE the newline arm uses $'\n' — a `$(printf '\n')` here would be an
    # EMPTY string (command substitution strips trailing newlines), collapsing
    # the pattern to `**` and refusing every path. Measured: it rejected a
    # perfectly ordinary /var/folders/... root.
    local _nl=$'\n'
    case "$env_root" in
      *'$'*|*'`'*|*\\*|*'"'*|*"$_nl"*)
        echo "  ! knowledge-store root NOT persisted: KNOWLEDGE_STORE_ROOT contains a character that is not safe to embed in a sourced conf line (one of \" \$ \` \\ or a newline) — ${env_root}" >&2
        echo "    The persisted form quotes the value, so that character would EXPAND when the conf is re-sourced and every consumer would silently resolve a DIFFERENT directory than the one you set. Use a path without them." >&2
        return 0
        ;;
    esac

    # Skip COMMENT lines: an unanchored whole-file match fires on
    # `# TODO: set KNOWLEDGE_STORE_ROOT here`, and the remedy below then sends
    # the operator hunting for a broken assignment that does not exist.
    if [ -f "$conf" ] && grep -v '^[[:space:]]*#' "$conf" 2>/dev/null | grep 'KNOWLEDGE_STORE_ROOT' >/dev/null; then
      echo "  ! knowledge-store root NOT persisted (provenance: conf-present-but-unusable): ${conf} already mentions KNOWLEDGE_STORE_ROOT, but it does not resolve to a usable absolute path." >&2
      echo "    Appending another line would be dead text (the var is already bound) and rewriting yours would be a clobber — fix that line by hand so it reads an absolute path." >&2
      return 0
    fi

    if ! mkdir -p "$(dirname "$conf")" 2>/dev/null; then
      echo "  ! could not create the machine-conf directory: $(dirname "$conf") (permissions?)" >&2
      return 1
    fi

    if [ ! -f "$conf" ]; then
      # A fresh conf gets a header naming what it is and the one idiom every
      # line in it must follow — an operator who later opens this file should
      # not have to reverse-engineer the precedence ladder from one line.
      {
        echo '#!/usr/bin/env bash'
        echo '# temperloop rung-3 MACHINE CONF — this host'"'"'s config overrides.'
        echo '# Sourced by workflows/scripts/build/build.config.sh (BUILD_CONFIG_MACHINE),'
        echo '# and — for the knowledge-store root alone — read back by'
        echo '# workflows/scripts/lib/knowledge_store.sh (_ks_machine_conf_root), so a bare'
        echo '# hook or launchd agent that never sources build.config.sh still finds the'
        echo '# store. Every line MUST use the assign-if-unset idiom so an exported env var'
        echo '# still wins; see docs/config-precedence.md.'
        echo '#'
        echo '# Created by "temperloop install". Hand-edit freely: install never rewrites a'
        echo '# line it did not add, and "temperloop uninstall" never removes this file.'
      } >"$conf" || {
        echo "  ! could not create the machine conf: ${conf} (permissions?)" >&2
        return 1
      }
    fi

    # shellcheck disable=SC2016  # the ${...} is literal shell text being WRITTEN into the conf, not expanded here
    if ! printf '\n# Knowledge-store root, persisted by `temperloop install` from the\n# KNOWLEDGE_STORE_ROOT set in that run'"'"'s environment (foundation#1771).\n: "${KNOWLEDGE_STORE_ROOT:=%s}"\n' "$env_root" >>"$conf"; then
      echo "  ! could not append to the machine conf: ${conf} (permissions?)" >&2
      return 1
    fi
    # VERIFY, do not claim. The dead-text guard above is textual, so it cannot
    # see any reason the appended line might not EXECUTE — a conf that ends in
    # `return 0`, an early-return guard, a conditional block, or an included
    # sub-file all leave the append inert while the grep finds nothing. Without
    # this re-probe the function prints "persisted" over a root that still
    # resolves to the default fallback: the same silent-success shape this
    # whole issue exists to close, one layer up. Re-ask the exact question a
    # bare consumer asks, and gate the success line on the answer.
    local verified
    verified="$(
      set +eu
      unset KNOWLEDGE_STORE_ROOT
      # shellcheck source=/dev/null
      . "$ks_lib" >/dev/null 2>&1
      _ks_machine_conf_root 2>/dev/null
    )"
    if [ "$verified" != "$env_root" ]; then
      echo "  ! appended a KNOWLEDGE_STORE_ROOT line to ${conf}, but a bare consumer still resolves '${verified:-<default fallback>}', not '${env_root}'." >&2
      echo "    Something earlier in that conf — an early return, a conditional, an included file — stops the line taking effect, so the appended block is inert. Remove it and set the root by hand." >&2
      return 0
    fi
    echo "  → persisted knowledge-store root into the rung-3 machine conf: ${env_root}"
    echo "    conf: ${conf}"
    echo "    Verified: a bare consumer (no build.config.sh in the chain) now resolves it."
    echo "    It was only an environment variable before this; every consumer that never sources build.config.sh (a hook, a launchd agent) now resolves it too."
    return 0
  fi

  # ---- 4. Nothing configured it: verify, don't silently proceed -----------
  # Same discriminator check_knowledge_root uses, so the two surfaces label the
  # same state identically: a conf FILE that exists but yields no usable root
  # is `conf-present-but-unusable`; no conf file at all is `default-fallback`.
  local provenance='default-fallback'
  [ -f "$conf" ] && provenance='conf-present-but-unusable'

  local fallback_root
  fallback_root="$(
    set +eu
    # shellcheck source=/dev/null
    . "$ks_lib" >/dev/null 2>&1
    ks_root 2>/dev/null
  )"

  echo "  WARN — knowledge-store root: ${provenance}. NOTHING configured it, so every consumer will read and write:"
  echo "    ${fallback_root}"
  echo "    The plain-files backend creates that directory on first append, so a wrong root fails SILENTLY and looks green."
  if [ "$provenance" = 'conf-present-but-unusable' ]; then
    echo "    Fix: ${conf} exists but sets no usable absolute KNOWLEDGE_STORE_ROOT — add one."
  else
    echo "    Fix: re-run this install with KNOWLEDGE_STORE_ROOT=<absolute path to your store> and it will be persisted to ${conf}, or write that file yourself."
  fi
  echo "    (A fresh install with no knowledge store yet is expected to land here — nothing is guessed on your behalf.)"
  echo "    Verify any time with: bash workflows/scripts/install/doctor.sh"
  return 0
}
