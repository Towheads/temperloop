#!/usr/bin/env bash
#
# Board adapter — the ONE sourced library that owns every GitHub Projects-v2
# board interaction for the dev-process scripts (claim.sh / capture.sh /
# worklist.sh, and eventually /build board-mirroring).
#
# Why this exists: four call sites used to re-implement the same board
# resolution dance (project view -> field-list -> item-list active-set page ->
# item-edit), copy-pasting the field-name strings ("Status", "Host/Session"),
# the option names ("In Progress", "Backlog"), the owner, and the item-list page
# footgun. A board rename broke all four, some silently. This library makes
# those a single edit point and — crucially — adds a test seam (`_board_gh`)
# so the claim/capture logic can finally be covered by fixture-replay tests.
# See dev-process-refactor-board-adapter.md for the full design.
#
# Two design rules carried over from lib/claim_marker.sh:
#   - resolve-by-NAME (robust to a board field being deleted + re-created with a
#     new id), never hard-code field/option ids;
#   - a SINGLE indirection seam (`_board_gh`) every board call routes through,
#     so tests override it to replay canned fixtures with zero network.
#
# Sourced, not executed:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/board.sh"

# --- identity + name constants (ONE place) --------------------------------
# A board rename is a one-line edit here; nothing downstream hard-codes these.
# These constants are a PUBLIC surface consumed by the sourcing scripts
# (claim.sh / capture.sh / worklist.sh) and future /build mirroring; some
# are read only across the `source` boundary, which shellcheck cannot see when
# linting this file in isolation. Hence the file-scoped SC2034 suppression.
# shellcheck disable=SC2034
BOARD_OWNER="Towheads"   # org owner; the board_owner() `*)` fallback for an unknown board (#330)  # denylist:allow — this repo's own real value, see board_repo() comment above
# Every governed board keys its worklist single-select on GitHub's built-in
# Status field (options: Backlog / Ready / In Progress / Done), so the
# built-in close->Done / reopen->In Progress automations — which can only target
# Status — drive the board. stageFind (3) consolidated onto Status in GH #340;
# foundation (4) was migrated to match in epic #24 (2026-06-02), at which point
# the former per-board board_status_field() shim collapsed to this one constant.
# ALL callers (claim.sh / worklist.sh / reconcile.sh / capture.sh) use it.
BOARD_FIELD_STATUS="Status"
BOARD_FIELD_HOSTSESSION="Host/Session"
BOARD_OPT_INPROGRESS="In Progress"
BOARD_OPT_BACKLOG="Backlog"
BOARD_OPT_READY="Ready"
BOARD_OPT_DONE="Done"
# Subsystem axis (foundation #97). A board-native single-select, orthogonal to the
# release-phase axis (which rides GitHub's built-in, read-only Milestone field —
# see board_item_milestone). stageFind seeded it from the milestones it had been
# mis-using as components (Datastore / Ingest / Extractor / …). Not every board
# defines it; board_set_component fails loudly (non-zero, no edit) where absent.
BOARD_FIELD_COMPONENT="Component"

# --- boards.conf registry seam (foundation #770) --------------------------
# The three registries below (board_repo/board_owner/board_project_number) are
# deliberately SEPARATE axes (repo-owner vs project-owner vs project-number —
# #330 paid for this distinction; never collapse them back to one). Each
# resolves its value through an optional external `boards.conf` FIRST, falling
# back to the built-in case map below when no conf entry exists. Discovery
# order (first hit wins):
#   1. machine-level: $XDG_CONFIG_HOME/foundation/boards.conf
#      (default ~/.config/foundation/boards.conf) — override BOARDS_CONF_MACHINE
#   2. repo-local override: workflows/scripts/board/boards.conf, next to this
#      lib — override BOARDS_CONF_REPO_LOCAL
#   3. the built-in case map (below) — the fallback every caller sees when
#      NEITHER conf file exists, byte-for-byte the same values as before this
#      seam existed. This matters because board.sh is synced (banner-stamped,
#      real-file copies — see `make sync-stagefind-board`) into stageFind and
#      the sync never carries a conf file: a consuming repo with no conf must
#      behave EXACTLY as it did pre-#770.
#
# Conf format: `board.<N>.<axis>=<value>` lines, axis in {repo,owner,project}.
# Blank lines and `#`-prefixed lines are ignored. Parsed with grep/cut only —
# NEVER sourced or eval'd, so a conf file cannot execute code. See
# workflows/scripts/board/boards.conf.example for the documented format.
_BOARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Echo the first EXISTING conf file in discovery order; rc 1 if neither exists
# (callers then fall through to their built-in case map).
_board_conf_file() {
  local f
  f="${BOARDS_CONF_MACHINE:-${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf}"
  [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  f="${BOARDS_CONF_REPO_LOCAL:-$_BOARD_LIB_DIR/../boards.conf}"
  [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}

# _board_conf_get <board> <axis> — echo the conf value + rc 0 on a hit; rc 1 on
# any miss (no conf file, or no matching key) so the caller falls back cleanly.
_board_conf_get() {
  local board="$1" axis="$2" file val
  file="$(_board_conf_file)" || return 1
  val="$(grep -m1 "^board\.${board}\.${axis}=" "$file" 2>/dev/null | cut -d= -f2-)"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# board number -> "owner/repo" for `gh issue create -R`. This is the ONE
# per-board "what" registry: onboarding a new board is a single line here (or
# in boards.conf), and every caller's --board switch resolves through it.
# Keeping the mapping here means capture.sh's --board switch and any future
# caller agree on it.
# denylist:allow — this built-in map is this repo's OWN real values, kept
# byte-identical for the boards.conf-less-consumer backward-compat guarantee
# documented above (#770); NOT an oversight. A stranger's fork replaces this
# whole case map (or ships a boards.conf) with their own org/repo values.
board_repo() {
  local v
  v="$(_board_conf_get "$1" repo)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo "Towheads/stageFind" ;;   # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    4) echo "Towheads/foundation" ;;  # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    5) echo "Towheads/ssmobile" ;;    # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    6) echo "Towheads/subsetwiki" ;;  # onboarded in the org  # denylist:allow — see comment above board_repo()
    7) echo "Towheads/temperloop" ;;  # the kernel tracker itself (F#808, issues-only — see board_backend below); formerly Towheads/foundation-kernel  # denylist:allow — see comment above board_repo()
    *) return 1 ;;
  esac
}

# board number -> the GitHub login that owns the board's Projects-v2 PROJECT (for
# `gh project … --owner`). This is the seam where a board migrated to a different
# owner expresses it: boards 3/4/5 were all migrated into this repo's own org (#330)
# and carry it here. $BOARD_OWNER remains only the `*)` fallback for an unknown
# board. Kept SEPARATE from board_repo()'s repo-owner: for a co-located board they're
# equal (all three are now), but the project-owner drives `gh project` while the
# repo-owner drives `repos/<owner>/<repo>` REST.
board_owner() {
  local v
  v="$(_board_conf_get "$1" owner)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3 | 4 | 5 | 6) echo "Towheads" ;; # all boards live in the org (#330; 6 onboarded)  # denylist:allow — this repo's own real value, see board_repo() comment above
    *) echo "$BOARD_OWNER" ;;     # fallback for an unknown board
  esac
}

# logical board number -> the gh project NUMBER under board_owner(). Migrating a
# board into an org restarts project numbering, so the migrated board carries its
# real org project number here (or in boards.conf) while every caller keeps
# using the stable logical `--board N`. Boards 3/4 were copied into the org
# (#330) where they landed as org projects #4 and #3 respectively (the order is
# incidental — the seam absorbs it). Twin of board_repo() — the per-board
# "which project" registry to board_repo()'s "which repo". Contains all
# renumbering churn inside this one function (the cross-process cache stays
# keyed on the LOGICAL number, so renumbering causes zero cache churn).
board_project_number() {
  local v
  v="$(_board_conf_get "$1" project)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo 4 ;;   # logical stageFind  -> org project #4
    4) echo 3 ;;   # logical foundation -> org project #3
    *) echo "$1" ;; # boards 5 (ssmobile) / 6 (subsetwiki) -> org project #5 / #6 (identity, incidental)
  esac
}

# --- tracker backend selector (foundation #799, "tracker seam") -----------
# A board is Projects-v2-backed (default) or ISSUES-ONLY: no Projects board is
# ever provisioned/queried and item CRUD + Status ride plain `fnd:`-namespaced
# GitHub labels on the repo's Issues instead. This is a FOURTH boards.conf
# axis, a peer to repo/owner/project (same discovery order, same grep/cut-only
# parsing — see boards.conf.example): `board.<N>.backend=issues`. There is
# deliberately NO GENERAL-PURPOSE built-in case-map entry defaulting an
# arbitrary board to "issues" — every board with no explicit `backend=issues`
# line resolves "projects" and takes the EXACT SAME Projects-v2 code path as
# before this seam existed (see test_issues_backend.sh's config-selection
# proof: unmentioned/absent-conf boards emit byte-identical `gh project …`
# argv). This is what makes the seam additive-only rather than a fork of the
# toolkit — see workflows/scripts/board/ISSUES-ONLY-BACKEND.md for the full
# label vocabulary + status-mapping contract the issues-only path implements.
#
# ONE deliberate, permanent, singular exception (F#808, Guard #3 of the
# kernel-vs-overlay routing rule): board 7 IS the temperloop tracker
# itself — its issues-only-ness is a structural fact of what board 7 means,
# not a per-deployment configuration choice a boards.conf should carry (and a
# real boards.conf committed inside kernel/ would embed this org's name in a
# file this checkout's own personal-token-denylist forbids it in — see
# board_repo()'s own board.7 case + its trailing `denylist:allow` marker,
# the one place a real org literal is sanctioned). A per-machine/per-repo
# boards.conf can still override board 7's `repo`/`backend` (checked FIRST,
# same discovery order as any other board) — this hard-codes only the
# DEFAULT any boards.conf-less consumer sees, exactly like board_repo()'s
# boards 3-6 already do for the `repo` axis.
#   board_backend <board#>  ->  "issues" | "projects" (default)
board_backend() {
  local v
  v="$(_board_conf_get "$1" backend)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    7) printf '%s\n' "issues"; return 0 ;;   # the kernel tracker (F#808) — see comment above
  esac
  printf '%s\n' "projects"
}

# True iff <board#> is configured for the issues-only backend. The single
# predicate every branch point below (board_resolve / board_resolve_item /
# board_item_list / board_set_status / board_create_many / board_capture_item)
# guards on, so onboarding a fifth branch point later is a one-line addition.
_board_is_issues_only() {
  [ "$(board_backend "$1")" = "issues" ]
}

# --- board NAME aliases for --board (temperloop #95) ----------------------
# Every --board switch accepts a board NAME as well as its logical number, so a
# human never has to touch the private number space (the number stays the SOLE
# internal key; names resolve to a number at the CLI/entrypoint boundary and
# nothing downstream is name-aware). Two name sources, checked in this order —
# same first-hit-wins discovery as every other axis:
#   1. a `board.<N>.name=<slug>` line in boards.conf (a SEVENTH axis, peer to
#      repo/owner/project/backend/cache — same grep-only, never-sourced parsing;
#      see boards.conf.example). This is how a stranger's fork names its own
#      boards without editing this lib.
#   2. the built-in name map below — this repo's OWN board names, kept here for
#      the boards.conf-less consumer (a synced board.sh with no conf must accept
#      `--board foundation` exactly as it accepts `--board 4`). These are app
#      names, NOT identity/credential tokens, so they are deliberately NOT on
#      the personal-token denylist (see personal-token-denylist.tsv's header).
# Matching is case-insensitive on the name; a bare integer is a NUMBER and
# passes straight through untouched (the cheap, dominant internal path — no conf
# read). An unknown name errors to stderr WITH the known-names list, rc 2.

# Built-in name -> logical number. Lowercased input; rc 1 on miss.
# A stranger's fork edits this map (or ships boards.conf board.<N>.name= lines).
_board_builtin_name_to_number() {
  case "$1" in
    stagefind)         echo 3 ;;
    foundation)        echo 4 ;;
    ssmobile)          echo 5 ;;
    subsetwiki)        echo 6 ;;
    kernel|temperloop) echo 7 ;;
    *) return 1 ;;
  esac
}

# The names the built-in map answers to (for the unknown-name error list).
_BOARD_BUILTIN_NAMES="stagefind foundation ssmobile subsetwiki kernel temperloop"

# boards.conf name -> number lookup (case-insensitive on the value). Parsed with
# a pure shell split, never eval/grep-with-user-regex, so a name with regex
# metacharacters can't misfire. rc 1 on no-conf / no-match.
_board_conf_name_to_number() {
  local want line n nm file
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  file="$(_board_conf_file)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      board.*.name=*)
        n="${line#board.}"; n="${n%%.name=*}"
        nm="${line#*.name=}"
        nm="$(printf '%s' "$nm" | tr '[:upper:]' '[:lower:]')"
        [ "$nm" = "$want" ] && { printf '%s' "$n"; return 0; }
        ;;
    esac
  done < "$file"
  return 1
}

# The full known-names list (built-in + every boards.conf board.<N>.name=),
# space-separated, for the unknown-name error message.
_board_known_names() {
  local names="$_BOARD_BUILTIN_NAMES" file line
  if file="$(_board_conf_file)"; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        board.*.name=*) names="$names ${line#*.name=}" ;;
      esac
    done < "$file"
  fi
  printf '%s' "$names"
}

# board_resolve_name <name-or-number> -> canonical logical NUMBER on stdout.
# The ONE shared resolver every --board switch and every lib entrypoint routes a
# board argument through. A bare integer passes through unchanged (backward
# compatible — the sole internal key is still the number). A name resolves via
# boards.conf then the built-in map. An unknown name prints an error + the known
# names to stderr and returns 2; an empty argument returns 2.
board_resolve_name() {
  local arg="$1" n
  case "$arg" in
    '')       printf 'board name or number required\n' >&2; return 2 ;;
    *[!0-9]*) : ;;                         # contains a non-digit -> treat as a name
    *)        printf '%s' "$arg"; return 0 ;;   # pure integer -> passthrough
  esac
  if n="$(_board_conf_name_to_number "$arg")"; then printf '%s' "$n"; return 0; fi
  if n="$(_board_builtin_name_to_number "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')")"; then
    printf '%s' "$n"; return 0
  fi
  printf 'unknown board name: %s\nknown board names: %s\n' "$arg" "$(_board_known_names)" >&2
  return 2
}

# --- issue-plane read-cache enable axis (F#988 Contract, cache-read-dispatch
# item) ----------------------------------------------------------------------
# A SIXTH boards.conf axis, a peer to repo/owner/project/backend/(milestone is
# read-side, not conf): `board.<N>.cache=on`. Default (omitted, or any value
# other than "on") is OFF — the whole-board issues-only read stays exactly the
# live `gh issue list` call it always was (see _board_issues_item_list below).
# This is deliberately an ENABLE/DISABLE switch only — every TUNING knob for
# the store itself (root dir, TTL) stays an env var on lib/cache.sh
# (CACHE_STORE_ROOT / CACHE_STORE_TTL), never a second boards.conf axis (see
# cache.sh's own "Tuning knobs" comment). Turning this on has NO effect unless
# the caller has ALSO sourced lib/cache.sh in the same process — board.sh
# itself never sources cache.sh (kept a one-way, additive-only layering; see
# cache.sh's own header) — _board_issues_item_list checks `declare -F
# cache_read` and falls back to the live read (with one stderr notice) when
# the axis is on but cache.sh isn't in scope. This is what keeps reconcile.sh
# (which never sources cache.sh) permanently on the live-read arm regardless
# of what a boards.conf sets this axis to — see reconcile.sh's own
# BOARD_CACHE_TTL=0 live-read-pin comment and test_reconcile.sh's Lens 3.
_board_cache_store_enabled() {
  [ "$(_board_conf_get "$1" cache 2>/dev/null)" = "on" ]
}

# --- the ONE test-injection seam ------------------------------------------
# Every board `gh` call goes through here. Production runs real gh; tests
# override this after sourcing (e.g. `_board_gh() { fake_gh "$@"; }`) to replay
# fixtures. Mirrors lib/claim_marker.sh's `_claim_marker_tmux`.
_board_gh() { GH_CALL_OP="${GH_CALL_OP:-board:${FUNCNAME[1]:-unknown}}" gh "$@"; }  # knob:exempt — call-attribution tag, computed per-call via FUNCNAME, not a static operator default

# --- cross-process read cache (Projects-v2 GraphQL relief) ----------------
# Every board read is a Projects-v2 GraphQL call against a 5,000-points/hr budget
# (GH #396). The `item-list` active-set page is the heavy one — its cost scales
# with the returned (non-Done) items. board_resolve's "one fetch per process" memoization lives
# in shell globals, which is useless to the dominant caller today: an ORCHESTRATED
# command (/triage, /build) runs each step in a SEPARATE bash process, so
# every step re-sources this lib and re-pays project-view + field-list +
# item-list. ~6-10 resolves across one command's bash blocks is what re-drained
# the budget (GH #93) even after the per-process work of GH #53/#396.
#
# So the cache is keyed by board number (structure also by resolved owner+project#;
# see _board_cache_file / #341) and lives ON DISK, surviving across those
# processes: within the TTL window a read-burst costs ONE fetch, not N.
#
# TWO CACHE CLASSES, split by how fast the data actually changes — caching them
# under ONE short TTL was the root drain (structure was 56% of board GraphQL: a
# long-lived session re-paid project-view + field-list EVERY step because the 90s
# window expired between steps, even though that data never changed):
#   - STRUCTURE (`project` view + `fields` list — the project node-id and the
#     field/option SCHEMA) is config-like: invariant under item edits and NEVER
#     mutated by this adapter (structural edits are rare, manual `gh project
#     field-create` / updateProjectV2Field ops). It gets a LONG ttl
#     (BOARD_STRUCTURE_TTL, 24h) and is invalidated only by board_bust_structure
#     after such an edit — not by the per-step clock.
#   - ITEM STATE (`items` — status/stamp/seq values) is volatile: it keeps the
#     SHORT ttl (BOARD_CACHE_TTL, 90s) AND write-invalidation. Correctness is held
#     by WRITE-INVALIDATION, not by reading live: every mutator busts the board's
#     items cache (see _board_cache_bust), so a read-after-write sees the new value
#     even across processes. The cross-session claim lock stays correct because its
#     readers use board_resolve_item, whose one-issue query is ALWAYS LIVE.
# BOARD_CACHE_TTL=0 is the master off-switch (fully live, both classes);
# BOARD_STRUCTURE_TTL=0 (with the cache on) forces just structure live.
#
# ACCEPTED residual gap (foundation #589): the close→Done cascade (GH #340) fires
# GitHub-side on issue-close, so NO adapter mutator runs to bust the items cache —
# a warm page can show a just-merged item as still non-Done until the 90s TTL
# elapses. This is deliberately left to self-heal on the TTL: it is rare (~1-2/mo),
# bounded (≤90s), and has no clean adapter hook (merges go through `gh pr merge`,
# not the adapter). Do NOT shorten the global TTL to chase it — that would worsen
# the far more common friction of whole-board re-resolves draining the shared
# 5,000-pt/hr GraphQL budget. board_create_many's staleness, by contrast, is
# handled: its board_set_status calls patch-or-bust the page for indexed items.
BOARD_CACHE_TTL="${BOARD_CACHE_TTL:-90}"
# Structure changes only on a manual board edit; board_bust_structure invalidates it.
BOARD_STRUCTURE_TTL="${BOARD_STRUCTURE_TTL:-86400}"
BOARD_CACHE_DIR="${BOARD_CACHE_DIR:-${TMPDIR:-/tmp}}"

# One file per (board, kind). kind defaults to `items` so the historical
# `subset-board-<n>-items.json` name is unchanged; board_resolve also caches
# `project` and `fields` (board structure, invariant under item edits).
#
# STRUCTURE kinds (project/fields) fold the RESOLVED owner + project-number into
# the name; items keeps the bare logical key. This is the #341 durable fix: a
# renumber/migration (board_project_number / board_owner change) shifts the
# structure key, so the next resolve naturally MISSES the old cache and re-fetches
# live — instead of serving a stale project id for up to BOARD_STRUCTURE_TTL (24h)
# and failing every WRITE with "item does not exist in the project". It self-heals
# on ANY pull or in-place adapter edit, no board_bust_structure needed (deploy-mini
# still busts as belt-and-suspenders). The old resolved-key files (e.g.
# `<cachekey>-board-4-<oldowner>-4-project.json`) are simply never read again post-rename;
# they age out of TMPDIR. items/* stay logical-keyed: their short TTL +
# write-invalidation already cover the renumber window, and the historical
# `subset-board-<n>-items.json` name (and its tests) stay stable.
_board_cache_file() {
  local board="$1" kind="${2:-items}"
  case "$kind" in
    project | fields)
      printf '%s/subset-board-%s-%s-%s-%s.json' "${BOARD_CACHE_DIR%/}" \
        "$board" "$(board_owner "$board")" "$(board_project_number "$board")" "$kind" ;;
    *)
      printf '%s/subset-board-%s-%s.json' "${BOARD_CACHE_DIR%/}" "$board" "${kind}" ;;
  esac
}

# The board whose state the in-shell globals currently describe — set by
# board_resolve / board_resolve_item so the item-id-only mutators (board_set_*,
# board_stamp) know which board's on-disk cache to invalidate after a write.
BOARD_CURRENT=""

# Drop a board's cached item-list so the next read re-fetches live. A write makes
# the cached page stale; busting here is what lets the cache default ON without
# breaking read-after-write across processes. Item edits never change board
# structure, so the project/fields caches are left intact — to invalidate STRUCTURE
# after a manual board edit, use board_bust_structure (below), not this. No-op when
# the board is unknown — a mutator with no prior resolve in this process couldn't
# have resolved the field ids it needs anyway.
_board_cache_bust() {
  local board="${1:-$BOARD_CURRENT}"
  [ -n "$board" ] || return 0
  rm -f "$(_board_cache_file "$board" items)" 2>/dev/null || true
}

# Splice ONE mutated field's new value into the cached items page IN PLACE, so a
# read-after-write stays correct WITHOUT busting the whole page (which would force
# the next read to re-paginate the heavy item-list — GH #157: 9 of 46 item-list
# calls fired within 30s of a write, re-fetching the whole board for a one-field
# change). The single-item mutators (board_set_status / board_set_component /
# board_stamp / board_set_number) call this on a SUCCESSFUL edit instead of
# _board_cache_bust, keeping the items page warm for the rest of the session.
#
#   _board_cache_patch_field <board#> <item-id> <field-name> <json-value>
#
# <json-value> is a JSON-ENCODED literal (a quoted string for single-select/text,
# a bare number for number fields) so jq writes the correct type. The flattened
# key MUST mirror board_resolve_item's reshape EXACTLY: the field name with its
# first letter lowercased (Status->status, Host/Session->host/Session, Seq->seq,
# Component->component), value = the option NAME / text / number just written.
#
# Falls back to the whole-page bust whenever an in-place splice can't be trusted:
# no board known, the cache file absent or STALE (past its ttl — patching a stale
# page would leave other items wrong), or the item not present in the cached page.
# In every fallback the next read simply re-fetches live — correct, just not warm.
# This is the targeted-patch counterpart to _board_cache_bust; multi-field /
# structural writes (board_set_milestone) keep busting the whole page.
_board_cache_patch_field() {
  local board="${1:-$BOARD_CURRENT}" item_id="$2" field_name="$3" json_value="$4"
  local cache key ttl patched
  [ -n "$board" ] || return 0
  cache="$(_board_cache_file "$board" items)"
  ttl="${BOARD_CACHE_TTL:-90}"
  # No fresh cached page to patch -> nothing warm to keep; bust (next read = live).
  if [ "$ttl" -le 0 ] || [ ! -f "$cache" ] || [ "$(_board_file_age "$cache")" -ge "$ttl" ]; then
    _board_cache_bust "$board"
    return 0
  fi
  # Flatten the field name the SAME way board_resolve_item / gh item-list do:
  # first letter lowercased, rest verbatim (Status->status, Host/Session->host/Session).
  key="$(printf '%s' "$field_name" | jq -Rr '(.[0:1] | ascii_downcase) + .[1:]')"
  # Set the key on the matching item only. If the cache holds no entry for this
  # item id (a stale page that predates the item), `changed` is false -> bust so
  # the next read picks it up live rather than serving a page missing the value.
  patched="$(
    jq --arg id "$item_id" --arg k "$key" --argjson v "$json_value" '
      if any(.items[]?; .id == $id)
      then { json: ( .items |= map(if .id == $id then .[$k] = $v else . end) ), changed: true }
      else { changed: false }
      end' "$cache" 2>/dev/null
  )" || { _board_cache_bust "$board"; return 0; }
  if [ "$(printf '%s' "$patched" | jq -r '.changed')" != "true" ]; then
    _board_cache_bust "$board"
    return 0
  fi
  printf '%s' "$patched" | jq '.json' >"$cache" 2>/dev/null || _board_cache_bust "$board"
}

# Public: invalidate a board's STRUCTURE cache (project view + field-list) so the
# next resolve re-reads the schema live. The adapter never mutates structure, so
# nothing auto-busts it; run this after a MANUAL structural edit (gh project
# field-create / updateProjectV2Field — e.g. adding a Status/Component option) so
# the long-lived BOARD_STRUCTURE_TTL cache doesn't keep serving the pre-edit
# schema. Drops ONLY structure (not the items page — that has its own short ttl +
# write-invalidation). Default board = BOARD_CURRENT; no-op when unknown.
board_bust_structure() {
  local board="${1:-$BOARD_CURRENT}"
  [ -n "$board" ] || return 0
  rm -f "$(_board_cache_file "$board" fields)" "$(_board_cache_file "$board" project)" \
    2>/dev/null || true
}

# Age of a file in whole seconds, or a large sentinel if absent/unstatable.
# stat(1) differs by platform — GNU `stat -c %Y` (Linux CI/hosts) vs BSD
# `stat -f %m` (macOS dev). Try GNU FIRST: BSD's `-f` is a different flag
# (--file-system) on GNU and exits 0 printing non-numeric text, so a BSD-first
# probe would short-circuit the fallback and yield garbage. Validate the result
# is all-digits before doing arithmetic on it; anything else → treat as stale.
_board_file_age() {
  local f="$1" mtime now
  [ -f "$f" ] || { echo 999999; return; }
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || true)"
  case "$mtime" in
    '' | *[!0-9]*) echo 999999; return ;;
  esac
  now="$(date +%s)"
  echo "$(( now - mtime ))"
}

# Build the `gh project item-list` argv for a WHOLE-BOARD read into the global
# array _BOARD_IL_ARGV (bash can't return arrays; both whole-board sites share this
# one builder so the knobs/order never drift). It filters to the ACTIVE (non-Done)
# slice server-side via the Projects `--query` syntax: board 3 crossed 200 TOTAL
# items (GH #168), and `gh project item-list --limit N` only ever returns the first
# page, so an unfiltered read silently truncated the active slice. Every whole-board
# consumer (board_resolve / worklist / reconcile / milestone / board_create_many)
# operates ONLY on non-Done items, so the Done tail is pure payload — dropping it
# keeps the active set well inside one page. Two knobs (matching the ${VAR:-default}
# idiom used for BOARD_CACHE_TTL):
#   BOARD_ITEM_LIMIT  (default 500) — page cap; gh paginates internally to reach it,
#                       so GraphQL cost scales with RETURNED items, not the ceiling.
#   BOARD_ITEM_QUERY  (default -status:Done) — Projects filter. `-status:Done` is
#                       STATUS-based (not `is:open` issue-state), so it still surfaces
#                       no-status items and closed-but-not-yet-Done DRIFT that
#                       reconcile must catch. Set it EMPTY to fetch ALL items incl.
#                       Done (escape hatch for a future reverse-drift audit).
# Sets _BOARD_IL_ARGV (the argv) and _BOARD_IL_QUERY (the effective query) so the
# cache layer can key its slot on the query (board_item_list).
_board_item_list_argv() {
  local lim="${BOARD_ITEM_LIMIT:-500}"
  _BOARD_IL_QUERY="${BOARD_ITEM_QUERY-"-status:Done"}"
  _BOARD_IL_ARGV=(project item-list "$(board_project_number "$1")" --owner "$(board_owner "$1")" --limit "$lim")
  [ -n "$_BOARD_IL_QUERY" ] && _BOARD_IL_ARGV+=(--query "$_BOARD_IL_QUERY")
  _BOARD_IL_ARGV+=(--format json)
}

# Drop PR-type cards from a whole-board read (foundation #223). The board's
# work-unit is the ISSUE; GitHub's "Auto-add to project" workflow also lands PRs,
# whose cards orphan at Status (none) forever — the close→Done cascade (GH #340)
# fires on issue-close, not PR-merge, so nothing ever moves a merged PR's card.
# Drops EXACTLY content.type "PullRequest"; Issue, DraftIssue, and absent/unknown
# types pass (the latter carry a null content.number, so they are inert in the
# number-keyed accessors). This is the read-side backstop to the source fix
# (the board's auto-add filter set to is:issue). Applied at BOTH raw whole-board
# exits — _board_item_list_fresh and board_item_list — so BOARD_ITEMS_JSON is
# issues-only no matter which path populated it.
_board_drop_pr_cards() {
  jq -c 'if has("items") then .items |= map(select((.content.type // "") != "PullRequest")) else . end'
}

# Strip ASCII control characters 0x00–0x1f from a whole-board read's raw TEXT
# (foundation #224). A raw control char inside an item title/body is invalid in a
# JSON string value, so it breaks jq's parse with a hard error — and because the
# whole-board read is bulk, ONE poisoned item takes down the entire list. This has
# RECURRED because earlier fixes patched it per-call-site (ccbc6868 added an inline
# `tr -d '\000-\037'` at ONE site; 92feec12 hit it again). The durable fix mirrors
# _board_drop_pr_cards (#223): ONE shared pipe-stage helper applied at the raw
# whole-board exits — _board_item_list_fresh (live) and board_item_list (cached) —
# AND at every per-issue / per-milestone REST→jq seam that reads a user-controlled
# body/description: board_blocked_by_open, board_parent_issue, board_active_milestones,
# board_set_milestone_description, and milestone.sh's _milestone_description /
# milestone_list (#614). Those single-item REST reads were the uncovered class: a
# gh-leaked literal control byte made their `… 2>/dev/null | jq` fail, the 2>/dev/null
# swallowed the error, and the function returned a SILENT wrong-empty answer
# ("not blocked" / "no parent" / "no active milestones") — which halted /triage.
# Crucially the helper runs on the raw TEXT *before* any jq sees it (control chars
# break jq, so a jq-based sanitizer can't fix its own input). tr never fails on this
# class of input, so it adds no new error path. INVARIANT: any new `_board_gh api …
# | jq` that reads issue/milestone content must route through this stage first.
_board_sanitize_control_chars() {
  LC_ALL=C tr -d '\000-\037'
}

# Always-live item-list fetch (the SINGLE active-set page; see _board_item_list_argv).
# The internal that never touches the cache — used by board_create_many's index-wait
# retry, which must read fresh to observe just-added items the cached page can't yet
# contain. Just-added items land in Backlog, so the non-Done filter never hides them.
# Captures the raw read first so _board_gh's fail-loud exit propagates (the jq
# PR-card filter would otherwise mask it); see _board_drop_pr_cards (#223).
_board_item_list_fresh() {
  _board_item_list_argv "$1"
  local raw
  raw="$(_board_gh "${_BOARD_IL_ARGV[@]}")" || return 1
  printf '%s' "$raw" | _board_sanitize_control_chars | _board_drop_pr_cards
}

# Cache-aware GraphQL read with fail-loud, don't-poison semantics.
#   _board_cached_read <board#> <kind> <gh-args...>
# Fresh-enough cache file → returns it with ZERO gh calls. Miss → reads live, and
# crucially NEVER caches an empty or failed result and returns NON-ZERO so the
# caller fails loudly instead of proceeding on empty JSON. That last part closes
# the silent-null corruption a drained budget used to cause (GH #93): board_resolve
# would capture empty stdout from a rate-limited gh and the accessors would then
# read null. gh's own rate-limit message still reaches stderr via the _board_gh
# seam; here we add a one-line hint and refuse to cache the garbage.
_board_cached_read() {
  local board="$1" kind="$2"; shift 2
  local cache out ttl
  # TTL by class: STRUCTURE (project/fields schema, invariant + never mutator-busted)
  # gets the long ttl; ITEM STATE (items) keeps the short ttl + write-invalidation.
  # BOARD_CACHE_TTL=0 stays the MASTER off-switch ("0 = fully live") — it disables
  # structure caching too, so a caller forcing live reads still gets them; only with
  # the cache on does structure take its own long BOARD_STRUCTURE_TTL.
  case "$kind" in
    project | fields)
      if [ "${BOARD_CACHE_TTL:-90}" -gt 0 ]; then ttl="${BOARD_STRUCTURE_TTL:-86400}"; else ttl=0; fi
      ;;
    *) ttl="${BOARD_CACHE_TTL:-90}" ;;
  esac
  cache="$(_board_cache_file "$board" "$kind")"
  if [ "$ttl" -gt 0 ] && [ "$(_board_file_age "$cache")" -lt "$ttl" ]; then
    # Sanitize on READ too (#443). The write path below strips control chars
    # BEFORE caching, but that doesn't cover a file dirtied by a pre-fix write,
    # an external/partial write, or an older adapter version — and the HIT path
    # used to `cat` it raw, serving control chars to every direct consumer
    # (board_resolve's BOARD_ITEMS_JSON, _board_cache_patch_field's jq). Strip on
    # read so the served value is canonical-clean regardless of how the file got
    # written (the #443 recurrence of #354). tr never fails on this class.
    _board_sanitize_control_chars < "$cache"
    return 0
  fi
  out="$(_board_gh "$@")" || {
    echo "board.sh: live read failed ($kind, board $board) — rate limit or auth?" >&2
    return 1
  }
  [ -n "$out" ] || {
    echo "board.sh: live read returned empty ($kind, board $board) — not caching" >&2
    return 1
  }
  # Strip unescaped control chars (U+0000–U+001F) from the raw gh response BEFORE
  # it is cached. gh can emit a literal control byte inside an issue body, which
  # makes the response invalid JSON (jq: "control characters … must be escaped").
  # board_item_list strips these on its read-OUTPUT, but the cache FILE kept the
  # raw bytes — so _board_cache_patch_field's jq runs DIRECTLY on an invalid file,
  # fails, and busts the page: the silent-empty board_item_id of #354. Sanitizing
  # at write makes the cache file canonical-clean for every direct consumer. (tr
  # also drops \t/\n, but those are insignificant JSON whitespace; the body text
  # that carried them is non-load-bearing and board_item_list already dropped it.)
  out="$(printf '%s' "$out" | _board_sanitize_control_chars)"
  if [ "$ttl" -gt 0 ]; then
    printf '%s' "$out" >"$cache" 2>/dev/null || true
  fi
  printf '%s' "$out"
}

# --- pre-flight GraphQL budget guard (GH #156) ----------------------------
# The heavy whole-board `item-list` active-set page is the dominant Projects-v2
# GraphQL cost; on a near-empty 5,000-pt/hr budget it fails with an opaque empty
# read (caught by _board_cached_read's fail-loud, but only AFTER the attempt).
# This pre-checks the budget BEFORE that heavy read, turning a silent drain into
# an early, legible stderr signal naming the remaining budget + reset time.
#
# It is a REST call (`gh api rate_limit`) — free, on REST's SEPARATE 5,000/hr
# bucket — so the check itself never spends GraphQL points. Routed through the
# `_board_gh` seam so tests stub it with zero network.
#
# Threshold: BOARD_BUDGET_GUARD_THRESHOLD (default 200). Set it to 0 to DISABLE
# the guard entirely (the opt-out). Behaviour:
#   - graphql.remaining >= threshold  -> silent, proceed (the common case);
#   - remaining < threshold           -> one-line stderr WARNING, proceed;
#   - remaining < threshold AND BOARD_BUDGET_GUARD=1 -> warn + return non-zero
#     (HARD-ABORT before the heavy read).
# Conservative by construction: any failure to read/parse the rate_limit (network
# hiccup, unexpected JSON) is swallowed and the guard PROCEEDS — it can never make
# board_resolve worse than today. Lives ONLY on the heavy whole-board path
# (board_resolve, and only when the items cache misses); board_resolve_item never
# calls it, so a claim never pays the latency.
#   _board_budget_guard <board#>  ->  0 = proceed, non-zero = hard-abort
_board_budget_guard() {
  local board="$1" threshold remaining reset now mins out
  threshold="${BOARD_BUDGET_GUARD_THRESHOLD:-200}"
  # Opt-out: threshold 0 (or non-numeric) disables the guard entirely.
  case "$threshold" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$threshold" -gt 0 ] || return 0
  # REST rate_limit read (free, separate bucket). Degrade gracefully on any error:
  # a failed/empty/garbled read must NOT block the resolve.
  out="$(_board_gh api rate_limit --jq '.resources.graphql.remaining, .resources.graphql.reset' 2>/dev/null)" || return 0
  remaining="$(printf '%s\n' "$out" | sed -n '1p')"
  reset="$(printf '%s\n' "$out" | sed -n '2p')"
  case "$remaining" in
    '' | *[!0-9]*) return 0 ;;
  esac
  # Healthy budget -> silent, proceed.
  [ "$remaining" -lt "$threshold" ] || return 0
  # Compute a human "resets in Nm" hint when the reset epoch is sane; omit it
  # otherwise (still warn) — never let a bad reset value break the guard.
  now="$(date +%s 2>/dev/null)"
  case "$reset" in
    '' | *[!0-9]*) mins="" ;;
    *)
      if [ -n "$now" ] && [ "$reset" -gt "$now" ]; then
        mins="$(( (reset - now + 59) / 60 ))"
      else
        mins=""
      fi
      ;;
  esac
  if [ -n "$mins" ]; then
    echo "board: graphql $remaining/5000, resets in ${mins}m — heavy whole-board read (board $board) may fail" >&2
  else
    echo "board: graphql $remaining/5000 — heavy whole-board read (board $board) may fail" >&2
  fi
  # Opt-in hard-abort; default is warn-only.
  if [ "${BOARD_BUDGET_GUARD:-0}" = "1" ]; then
    echo "board: BOARD_BUDGET_GUARD=1 — refusing the whole-board read on a near-empty budget" >&2
    return 1
  fi
  return 0
}

# --- issues-only backend: fnd: label vocabulary + item CRUD/status --------
# See ISSUES-ONLY-BACKEND.md (sibling file) for the full contract. Summary:
# item state rides `fnd:<field-slug>:<value-slug>` labels on the plain GitHub
# issue (`fnd:status:ready`, `fnd:status:in-progress`, `fnd:component:ingest`,
# …); "Done" is the ONE exception — it carries NO label, it is simply the
# issue being CLOSED (closing strips any residual fnd:status:* label; a
# read of a closed issue always reports status "Done" regardless of labels).
# No Projects-v2 call is ever made on this path — board_backend gates every
# branch point below before any `gh project …` argv is built.

# "In Progress" -> "in-progress" (lowercase, spaces collapsed to hyphens).
_board_issues_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-'
}

# "fnd:status:" for field-name "Status", "fnd:component:" for "Component" —
# generic over ANY single-select-shaped field name via the same slugger, so a
# future field axis (beyond Status/Component) needs no new plumbing here.
_board_issues_label_prefix() {
  printf 'fnd:%s:' "$(_board_issues_slug "$1")"
}

# Shared jq `def`s for reshaping a raw `gh issue list`/`gh api issues/<n>`
# response into the SAME item shape board_resolve_item / board_item_list
# produce for the Projects-v2 path — {id, content:{number,title,type}, status,
# component, "host/Session"} — so every downstream accessor (board_item_id /
# board_item_title / a caller's own `.status`/`.component`/`.["host/Session"]`
# read — e.g. reconcile.sh's foreign-claim detector, worklist.sh's owner
# column) works UNCHANGED regardless of backend. `issue_item($n)` expects `.`
# to be the raw issue object (labels + state + title) and $n to be its issue
# number.
#   unslug: "in-progress" -> "In Progress" (inverse of _board_issues_slug,
#     good enough for the closed status vocabulary + any Component slug — see
#     ISSUES-ONLY-BACKEND.md's round-trip note). NOT applied to the
#     Host/Session claim stamp below — that is a free-text field (like its
#     Projects-v2 counterpart, a --text field rather than a single-select), so
#     unslugging (which lowercases) would corrupt a mixed-case hostname and
#     silently break the foreign-host comparison board_claim_contended /
#     reconcile.sh rely on. The stamp is stored and read back VERBATIM.
#   labels: the RAW label-name array (foundation #801, split 3/3 — the funnel-
#     integration "D3 seam" fix). A caller like funnel-tick.sh reads a Ready
#     item's ordinary GitHub labels directly (`spike`, `Foundational`,
#     `needs-clarification`, `funnel-escalated`, `funnel-merge-pending` — none
#     of them `fnd:`-namespaced) to classify/gate it; the Projects-v2 path
#     already exposes this for free, because board_item_list/_board_item_list_fresh
#     pass `gh project item-list`'s own raw JSON straight through (gh's default
#     item-list output carries a top-level `labels` array for Issue content —
#     see board_item_list's header comment), and board.sh reshapes NONE of it.
#     Before this fix the issues-only reshape below extracted only the
#     `fnd:`-prefixed labels into status/component/host-session and DROPPED
#     every other label — so a live funnel-tick against an issues-only board
#     could never see `spike`/`Foundational`/etc. and every Ready item
#     silently misclassified as a fresh Operational kind:code drive. Emitting
#     the full, unfiltered label-name list here (fnd: ones included — harmless,
#     since a `. == "spike"` equality check never matches `"fnd:status:ready"`)
#     makes the issues-only item shape a byte-for-byte structural match for the
#     Projects-v2 one on this key too. See ISSUES-ONLY-BACKEND.md § Funnel
#     integration and tests/test_board_dual_adapter.sh (the parity proof).
#   milestone: the item's release-phase milestone as { title } (temperloop#154 —
#     the same class of dropped-field bug the #801 labels passthrough fixed).
#     board_item_milestone reads `.milestone.title`; the Projects-v2 path gets it
#     for free (gh project item-list emits `.milestone = {title, description,
#     dueOn}`), but the issues-only reshape used to drop it entirely, so
#     board_item_milestone always returned empty on this backend — which silently
#     defeated /triage's active-milestone intake filter (every item read as
#     unmilestoned, so a Backlog item on an INACTIVE milestone was wrongly intook
#     instead of deferred). Emitting `{ title }` here (omitted when the issue has
#     no milestone, matching the component/host optional-field style) makes
#     board_item_milestone work unchanged on both backends. The whole-board live
#     read (_board_issues_item_list) must request `milestone` in its `gh issue
#     list --json` field list for this to be populated; the single-issue read
#     (_board_issues_resolve_item via `gh api …/issues/<n>`) carries it already.
read -r -d '' _BOARD_ISSUES_JQ_DEFS <<'JQ_DEFS' || true
def unslug: split("-") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ");
def issue_item($n):
  (.labels // [] | map(.name)) as $labels
  | (.state // "open") as $state
  | ( ($labels | map(select(test("^fnd:status:")))) as $sl
      | if ($sl | length) > 0 then ($sl[0] | sub("^fnd:status:"; "")) else "" end ) as $status_slug
  | ( ($labels | map(select(test("^fnd:component:")))) as $cl
      | if ($cl | length) > 0 then ($cl[0] | sub("^fnd:component:"; "")) else "" end ) as $comp_slug
  | ( ($labels | map(select(test("^fnd:host/session:")))) as $hl
      | if ($hl | length) > 0 then ($hl[0] | sub("^fnd:host/session:"; "")) else "" end ) as $host_session
  | { id: ("ISSUE_" + ($n | tostring)),
      content: { number: $n, title: (.title // ""), type: "Issue" },
      labels: $labels }
    + ( if $state == "closed" then { status: "Done" }
        elif $status_slug != "" then { status: ($status_slug | unslug) }
        else {} end )
    + ( if $comp_slug != "" then { component: ($comp_slug | unslug) } else {} end )
    + ( if $host_session != "" then { "host/Session": $host_session } else {} end )
    + ( if (.milestone.title // "") != "" then { milestone: { title: .milestone.title } } else {} end );
JQ_DEFS

# Whole-board (active-set) read for an issues-only board: every OPEN issue,
# reshaped to the shared item form. Mirrors the Projects path's `-status:Done`
# active-set convention for free — `--state open` already excludes the Done
# (closed) tail, no separate filter needed.
#
# --- PLANE MAP (F#988 Contract, cache-read-dispatch item) -------------------
# This function serves the ISSUE PLANE: the whole corpus of a repo's GitHub
# Issues (title/labels/state — everything this backend's item IS, since an
# issues-only board has no item distinct from its issue). It is served either
# LIVE (a `gh issue list` REST call, always was) or, when `board.<N>.cache=on`
# AND lib/cache.sh has been sourced by the caller, from cache.sh's on-disk
# issue-cache STORE (see cache.sh's header + CACHE-STORE.md). Either way this
# draws on REST's separate 5,000/hr bucket, never the Projects-v2 GraphQL
# budget board.sh's OWN item-plane cache above (_board_cached_read /
# BOARD_CACHE_TTL) exists to protect — that cache is the unrelated ITEM PLANE:
# Projects-v2 board-item field values (Status/Component/etc as GraphQL sees
# them), unchanged by this item and still the only cache a Projects-v2-backed
# board ever reads through. The two planes never overlap: a Projects-v2 board
# has no issue-plane store to read (this function is never called for one —
# board_item_list only reaches here via _board_is_issues_only), and an
# issues-only board has no item-plane cache to read (there is no Projects
# board to page). See cache.sh's own header for the store-side half of this
# map.
#   _board_issues_item_list <board#>  ->  {"items":[...]} JSON on stdout
_board_issues_item_list() {
  local board="$1" repo lim raw

  repo="$(board_repo "$board")" || return 1
  lim="${BOARD_ITEM_LIMIT:-500}"

  if _board_cache_store_enabled "$board"; then
    if declare -F cache_read >/dev/null 2>&1; then
      # cache_read serves warm-and-fresh with ZERO gh calls; on a miss/stale
      # store it pays exactly one live refresh itself (cache.sh's own
      # degradation contract — one stderr notice, never fabricated data) and
      # this function does not layer a second live fallback on top of that.
      # Snapshot rows are ALL states; filter to open here (mirrors the live
      # arm's `--state open`) — note BOARD_ITEM_LIMIT is a live-arm-only knob:
      # the store is not paginated/truncated (a later perf pass can add a cap
      # if an issues-only repo's corpus ever makes this the bottleneck).
      raw="$(cache_read "$repo")" || return 1
      printf '%s' "$raw" | _board_sanitize_control_chars | jq -s -c "
        $_BOARD_ISSUES_JQ_DEFS
        { items: [ .[] | select((.state // \"open\") == \"open\") | issue_item(.number) ] }
      "
      return $?
    fi
    echo "board: cache enabled for board $board (board.$board.cache=on) but lib/cache.sh is not sourced in this process — falling back to a live (uncached) read" >&2
  fi

  raw="$(_board_gh issue list -R "$repo" --state open --limit "$lim" \
        --json number,title,labels,milestone 2>/dev/null)" || {
    echo "board: live read failed (issues, board $board) — rate limit or auth?" >&2
    return 1
  }
  [ -n "$raw" ] || raw="[]"
  printf '%s' "$raw" | _board_sanitize_control_chars | jq -c "
    $_BOARD_ISSUES_JQ_DEFS
    { items: [ .[] | issue_item(.number) ] }
  "
}

# Single-issue, always-live read (the issues-only counterpart to
# board_resolve_item's targeted GraphQL query) — used by the mutating callers
# (claim/status-move) that must see fresh state. Unlike the whole-board read
# this DOES observe a just-closed issue (Done), since `gh api issues/<n>`
# doesn't filter by state.
#   _board_issues_resolve_item <board#> <issue#>  -> sets BOARD_ITEMS_JSON
_board_issues_resolve_item() {
  local board="$1" issue="$2" repo raw
  repo="$(board_repo "$board")" || return 1
  raw="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  BOARD_ITEMS_JSON="$(
    printf '%s' "$raw" | _board_sanitize_control_chars | jq -c --argjson n "$issue" "
      $_BOARD_ISSUES_JQ_DEFS
      { items: [ issue_item(\$n) ] }
    "
  )"
  BOARD_CURRENT="$board"
}

# Memoize `fnd:` label creation within this process (repo|label key) so a
# burst of status writes against the same repo pays `gh label create` at most
# once per label, not once per call. Plain string, not an associative array —
# board.sh must stay portable to macOS's stock bash 3.2 (no assoc arrays).
#
# $3 (color) and $4 (description) are optional overrides for callers that
# aren't creating an `fnd:` tracker label (e.g. capture.sh's work-class
# labels, Operational/Foundational) — default to the original fnd: tracker
# color/description so every existing call site (which passes only repo+label)
# is unaffected.
_BOARD_ISSUES_LABELS_ENSURED=""
_board_issues_ensure_label() {
  local repo="$1" label="$2" color="${3:-fbca04}" desc="${4:-fnd: tracker label (issues-only backend)}" key
  key="$repo|$label"
  case " $_BOARD_ISSUES_LABELS_ENSURED " in
    *" $key "*) return 0 ;;
  esac
  _board_gh label create "$label" -R "$repo" --color "$color" \
    --description "$desc" >/dev/null 2>&1 || true
  _BOARD_ISSUES_LABELS_ENSURED="$_BOARD_ISSUES_LABELS_ENSURED $key"
  return 0
}

# The issues-only write path board_set_status (and, via it, board_set_component)
# delegate to for an ISSUE_* item id. Emulates a single-select: at most one
# `fnd:<field>:*` label at a time. Status additionally drives open/closed:
# target "Done" -> strip any fnd:status:* label + CLOSE; any other target ->
# ensure the label + REOPEN if the issue was closed. Both the close/reopen and
# the label add/remove are read-before-write (one `gh api issues/<n>` fetch)
# so an already-correct state is a no-op, not a redundant/erroring gh call.
# Best-effort write-through invalidation (F#988 Contract, cache-read-dispatch
# item): dirty the canonical issue-cache store's entry for <repo> after a
# SUCCESSFUL issues-only mutation, so a following whole-board read (when
# board.<N>.cache=on) doesn't keep serving a pre-write snapshot for the rest
# of the store's TTL window. A pure no-op — never fails the caller — when
# lib/cache.sh has not been sourced in this process (board.sh has no hard
# dependency on it, see cache.sh's own header) or when no store yet exists
# for this repo (cache_dirty itself no-ops then; see cache.sh's cache_dirty).
#   _board_cache_dirty_after_write <owner/repo>
_board_cache_dirty_after_write() {
  declare -F cache_dirty >/dev/null 2>&1 && cache_dirty "$1" >/dev/null 2>&1
  return 0
}

#   _board_issues_set_field <ISSUE_n> <field-name> <option-name>
_board_issues_set_field() {
  local item_id="$1" field_name="$2" opt_name="$3"
  local issue repo prefix target_label issue_json state cur l is_done=0 already_present=0

  issue="${item_id#ISSUE_}"
  repo="$(board_repo "${BOARD_CURRENT:-}")" || {  # knob:exempt — internal already-resolved board state, not an operator default
    echo "board: _board_issues_set_field — no current board (call board_resolve_item first)" >&2
    return 1
  }
  prefix="$(_board_issues_label_prefix "$field_name")"

  if [ "$field_name" = "$BOARD_FIELD_STATUS" ] && [ "$opt_name" = "$BOARD_OPT_DONE" ]; then
    is_done=1
  else
    target_label="${prefix}$(_board_issues_slug "$opt_name")"
    _board_issues_ensure_label "$repo" "$target_label" || return 1
  fi

  issue_json="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null | _board_sanitize_control_chars)" || return 1
  [ -n "$issue_json" ] || return 1
  state="$(printf '%s' "$issue_json" | jq -r '.state // "open"')"
  cur="$(printf '%s' "$issue_json" | jq -r --arg p "$prefix" '.labels[]?.name | select(startswith($p))')"

  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$is_done" -eq 0 ] && [ "$l" = "$target_label" ]; then
      already_present=1
      continue
    fi
    _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1 || true
  done <<<"$cur"

  # Skip a redundant add when the target label is already the issue's only
  # fnd:<field>:* label (re-setting the same status/component is then a pure
  # no-op at the gh-call level, not just idempotent at the label-set level).
  if [ "$is_done" -eq 0 ] && [ "$already_present" -eq 0 ]; then
    _board_gh issue edit "$issue" -R "$repo" --add-label "$target_label" >/dev/null || return 1
  fi

  if [ "$field_name" = "$BOARD_FIELD_STATUS" ]; then
    if [ "$is_done" -eq 1 ]; then
      [ "$state" = "closed" ] || { _board_gh issue close "$issue" -R "$repo" >/dev/null || return 1; }
    else
      [ "$state" = "open" ] || { _board_gh issue reopen "$issue" -R "$repo" >/dev/null || return 1; }
    fi
  fi
  _board_cache_dirty_after_write "$repo"
  return 0
}

# Free-text label stamp for the issues-only backend — board_stamp's ISSUE_*
# counterpart to _board_issues_set_field's single-select emulation (foundation
# #800, claim/edges split; board_stamp/board_set_number were explicitly left
# "out of scope, fail loud" by the #799 split this one builds on). UNLIKE
# status/component, a free-text value (e.g. a Host/Session claim stamp
# "host:sess8") is stored VERBATIM as the label suffix — no slugging — because
# slugging lowercases, which would corrupt a mixed-case hostname and silently
# break the foreign-host comparison board_claim_contended / reconcile.sh rely
# on. At most one `fnd:<field-slug>:*` label of this prefix is kept at a time
# (same single-value-per-field convention as status/component, read-before-
# write so an already-correct stamp is a no-op). An empty <text> CLEARS the
# field (strips the label, adds nothing) mirroring board_stamp's Projects-v2
# `--clear` semantics (foundation #259) — this is what makes build's epic
# park-back stamp-clear actually clear on an issues-only board too.
#
# Label-count note: distinct stamp VALUES accumulate as distinct repo-level
# label objects over the tracker's lifetime (there is no cheap "is this label
# still referenced anywhere" check to safely `gh label delete` on removal —
# doing so could yank a label still worn by a DIFFERENT issue the same
# host/session claimed concurrently). Growth is bounded by the number of
# distinct host:session8 stamps that have ever claimed something on this repo
# (`_board_issues_ensure_label` already memoizes/no-ops a re-create), not by
# the number of claims — acceptable for a tracker's realistic session volume;
# a future cleanup pass could sweep orphaned `fnd:host/session:*` labels if it
# ever becomes a real problem.
#   _board_issues_stamp_field <ISSUE_n> <field-name> <text>
_board_issues_stamp_field() {
  local item_id="$1" field_name="$2" text="$3"
  local issue repo prefix target_label issue_json cur l already_present=0

  issue="${item_id#ISSUE_}"
  repo="$(board_repo "${BOARD_CURRENT:-}")" || {  # knob:exempt — internal already-resolved board state, not an operator default
    echo "board: _board_issues_stamp_field — no current board (call board_resolve_item first)" >&2
    return 1
  }
  prefix="$(_board_issues_label_prefix "$field_name")"

  if [ -n "$text" ]; then
    target_label="${prefix}${text}"
    _board_issues_ensure_label "$repo" "$target_label" || return 1
  fi

  issue_json="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null | _board_sanitize_control_chars)" || return 1
  [ -n "$issue_json" ] || return 1
  cur="$(printf '%s' "$issue_json" | jq -r --arg p "$prefix" '.labels[]?.name | select(startswith($p))')"

  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -n "$text" ] && [ "$l" = "$target_label" ]; then
      already_present=1
      continue
    fi
    _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1 || true
  done <<<"$cur"

  if [ -n "$text" ] && [ "$already_present" -eq 0 ]; then
    _board_gh issue edit "$issue" -R "$repo" --add-label "$target_label" >/dev/null || return 1
  fi
  _board_cache_dirty_after_write "$repo"
  return 0
}

# Detect whether <issue#> is already claimed by ANOTHER session BEFORE writing
# a new claim over it (foundation #800, extended to the Projects-v2 arm by a
# later fix — see below). Originally an issues-only-only pre-check; the
# Projects-v2 path used to have no such check and silently overwrote a foreign
# claim (relying entirely on reconcile.sh's separate, report-only pass to
# surface it after the fact — see reconcile.sh's "foreign claim" bucket). It is
# cheap on BOTH backends: the caller (claim.sh) has already resolved the item
# via board_resolve_item before calling this, so this is a pure jq read of the
# already-fetched BOARD_ITEMS_JSON, no extra `gh`/GraphQL call — board_resolve_item
# reshapes a Projects-v2 single-item resolve into the SAME {status, "host/Session"}
# item shape the issues-only backend produces (see board_resolve_item's field-
# flattening jq and _board_issues_resolve_item's issue_item def), so the check
# below is backend-agnostic and needs no `_board_is_issues_only` branch.
#
# CONTENDED means: the issue is currently In Progress AND carries an existing
# Host/Session stamp that is PRESENT and DIFFERENT from the stamp about to be
# written. Two cases are deliberately NOT contended (mirroring the Projects-v2
# adoption behavior test_claim.sh case 3 pins):
#   - re-claiming with the SAME stamp (idempotent self-reclaim), and
#   - an In-Progress item with NO existing stamp (adopting/repairing a
#     half-claim, the #103 failure mode — claim writes unconditionally there).
#   board_claim_contended <board#> <issue#> <new-stamp>
#     -> prints the FOREIGN existing stamp + rc 0 if contended
#        rc 1 (nothing printed) if safe to claim
board_claim_contended() {
  local issue="$2" new_stamp="$3" status existing
  status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .status // ""')"
  [ "$status" = "$BOARD_OPT_INPROGRESS" ] || return 1
  existing="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .["host/Session"] // ""')"
  [ -n "$existing" ] || return 1
  [ "$existing" = "$new_stamp" ] && return 1
  printf '%s\n' "$existing"
  return 0
}

# Issues-only counterpart to board_create_many: there is no Projects board to
# item-add to (and so no index-lag retry to absorb — a label write is
# synchronous REST, not an async Projects-v2 mutation), so "landing an item"
# collapses to just labeling it Backlog. The issues already exist repo-side
# (gh issue create is the caller's job, same as the Projects path).
#   _board_issues_create_many <board#> <url1> <num1> [<url2> <num2> ...]
_board_issues_create_many() {
  local board="$1"; shift
  local url num item_id
  BOARD_CURRENT="$board"
  while [ "$#" -ge 2 ]; do
    url="$1"; num="$2"; shift 2
    item_id="ISSUE_$num"
    board_set_status "$item_id" "$BOARD_OPT_BACKLOG" || \
      echo "warning: #$num (issues-only board $board) could not be labeled Backlog" >&2
  done
  return 0
}

# --- resolve once, cache across processes ---------------------------------
# A `project view`, a `field-list`, and an `item-list` active-set page, EACH served
# from the on-disk cache when warm (GH #93) so a /triage|/build step that
# re-resolves in a fresh process within the TTL pays zero GraphQL. Populates
# module globals reused by every accessor below.
#
#   board_resolve <board#>
#
# Sets: BOARD_PROJECT_ID, BOARD_FIELDS_JSON, BOARD_ITEMS_JSON, BOARD_CURRENT.
# Returns non-zero (without completing) if any read fails or comes back empty —
# so a rate-limited run fails loudly instead of leaving the accessors on null
# (the old silent-corruption mode). For a caller that touches exactly ONE issue,
# prefer board_resolve_item (below): it skips the expensive whole-board item-list
# AND stays always-live for the claim lock (GH #53).
board_resolve() {
  local board pv cache ttl
  board="$(board_resolve_name "$1")" || return 1
  if _board_is_issues_only "$board"; then
    BOARD_PROJECT_ID=""
    BOARD_FIELDS_JSON='{"fields":[]}'
    BOARD_ITEMS_JSON="$(board_item_list "$board")" || return 1
    BOARD_CURRENT="$board"
    return 0
  fi
  pv="$(_board_cached_read "$board" project \
        project view "$(board_project_number "$board")" --owner "$(board_owner "$board")" --format json)" || return 1
  BOARD_PROJECT_ID="$(printf '%s' "$pv" | jq -r '.id')"
  BOARD_FIELDS_JSON="$(_board_cached_read "$board" fields \
        project field-list "$(board_project_number "$board")" --owner "$(board_owner "$board")" --format json)" || return 1
  # Pre-flight budget guard ONLY when the heavy item-list is about to read LIVE
  # (cache miss / off / expired) — never on a warm-cache hit (no GraphQL spent)
  # and never in board_resolve_item (so a claim never pays the latency). Mirror
  # _board_cached_read's hit predicate so the guard fires exactly when the read will.
  cache="$(_board_cache_file "$board" items)"
  ttl="${BOARD_CACHE_TTL:-90}"
  if [ "$ttl" -le 0 ] || [ "$(_board_file_age "$cache")" -ge "$ttl" ]; then
    _board_budget_guard "$board" || return 1
  fi
  BOARD_ITEMS_JSON="$(board_item_list "$board")" || return 1
  BOARD_CURRENT="$board"
}

# --- resolve ONE item, without the full-board page ------------------------
# board_resolve pulls the `item-list` active-set page — the Projects-v2 GraphQL call whose
# point cost scales with the non-Done items and drained the 5,000-pt/hr
# budget when a session fired it once per process across a claim/set-status burst
# (GH #53). Single-item callers don't need the whole board: this serves the project
# id + field-list from the shared cross-process cache (board structure, invariant
# under item edits — GH #141), and looks up the ONE issue's project item LIVE via a
# targeted GraphQL query instead of paginating every item.
#
# It sets the SAME globals as board_resolve (BOARD_PROJECT_ID, BOARD_FIELDS_JSON,
# BOARD_ITEMS_JSON), and reshapes the item into the identical `gh project
# item-list` form — `{id, content:{number,title,type}, <flattened single-select /
# text / number fields like status, host/Session, seq>}` — so EVERY accessor
# (board_item_id / board_item_title / board_field_id / board_option_id) and every
# mutator works against it unchanged; BOARD_ITEMS_JSON simply carries the one
# resolved item. The ITEM read is always live (no cache): the single-item callers
# are the mutating ones (the cross-session claim lock, a Done/In-Progress move) and
# must see fresh status — only the structure reads (project/fields) are cached.
#
# Drop-in for board_resolve at any caller that touches exactly ONE issue
# (claim.sh; a single Done / In-Progress move; a one-item contention read). The
# full board_resolve stays for callers that scan the whole board — worklist.sh,
# reconcile.sh, and the /triage + board_create_many burst paths.
#   board_resolve_item <board#> <issue#>
# Returns non-zero (without setting state) if <board#> is not a known board.
board_resolve_item() {
  local board issue="$2" repo owner name pv
  board="$(board_resolve_name "$1")" || return 1
  if _board_is_issues_only "$board"; then
    _board_issues_resolve_item "$board" "$issue"
    return $?
  fi
  repo="$(board_repo "$board")" || return 1
  owner="${repo%/*}"; name="${repo#*/}"
  # project-view + field-list are board STRUCTURE (project id, field/option schema) —
  # invariant under item edits, and never busted by the single-item mutators (see
  # _board_cache_bust). So serve them from the SAME cross-process cache board_resolve
  # uses (GH #141): a long-lived session firing many single-item ops (claim / status
  # move) re-paid these two GraphQL calls EVERY time before this — the dominant drain
  # in the #141 attribution log. Only the one-issue query below stays always-live.
  pv="$(_board_cached_read "$board" project \
        project view "$(board_project_number "$board")" --owner "$(board_owner "$board")" --format json)" || return 1
  BOARD_PROJECT_ID="$(printf '%s' "$pv" | jq -r '.id')"
  BOARD_FIELDS_JSON="$(_board_cached_read "$board" fields \
        project field-list "$(board_project_number "$board")" --owner "$(board_owner "$board")" --format json)" || return 1
  # ONE issue's project item + its field values, reshaped to the item-list form.
  # The `(field name with first letter lowercased)` keying mirrors how `gh project
  # item-list --format json` flattens single-selects/text/number (Status->status,
  # Host/Session->host/Session, Seq->seq), so the accessors see an identical item.
  # SC2016: the `$owner`/`$name`/`$num` in the query are GraphQL variables (bound
  # via -f/-F below), NOT shell expansions — the single quotes are intentional.
  # shellcheck disable=SC2016
  BOARD_ITEMS_JSON="$(
    _board_gh api graphql \
      -f owner="$owner" -f name="$name" -F num="$issue" \
      -f query='
        query($owner:String!,$name:String!,$num:Int!){
          repository(owner:$owner,name:$name){
            issue(number:$num){
              title
              projectItems(first:20){
                nodes{
                  id
                  project{ number }
                  fieldValues(first:50){
                    nodes{
                      __typename
                      ... on ProjectV2ItemFieldSingleSelectValue{ name field{ ... on ProjectV2FieldCommon{ name } } }
                      ... on ProjectV2ItemFieldTextValue{ text field{ ... on ProjectV2FieldCommon{ name } } }
                      ... on ProjectV2ItemFieldNumberValue{ number field{ ... on ProjectV2FieldCommon{ name } } }
                    }
                  }
                }
              }
            }
          }
        }' |
      _board_sanitize_control_chars |
      jq --argjson b "$(board_project_number "$board")" --argjson n "$issue" '
        (.data.repository.issue // {}) as $i
        | { items: [
              ($i.projectItems.nodes // [])[]
              | select(.project.number == $b)
              | { id, content: { number: $n, title: ($i.title // ""), type: "Issue" } }
                + ( [ (.fieldValues.nodes // [])[]
                      | select((.field.name? // null) != null and (.name // .text // .number) != null)
                      | { ( (.field.name[0:1] | ascii_downcase) + .field.name[1:] ): (.name // .text // .number) } ]
                    | add // {} ) ] }'
  )"
  # Single-item resolve reads LIVE and never writes the full-list cache, but it
  # still records the board so a following mutator busts the right cache file.
  BOARD_CURRENT="$board"
}

# Fetch just the item-list for a board (the SINGLE active-set page; see
# _board_item_list_argv) without the field-list/project-view that board_resolve
# also does. For read-only callers like worklist.sh that only need the items and
# never resolve ids. The cached page now holds the ACTIVE (non-Done) slice — which
# is exactly what every whole-board consumer wants — under the unchanged cache
# filename.
#
# Cache-aware via _board_cached_read: a fresh-enough on-disk copy is returned with
# no GraphQL hit; a miss fetches live, caches a non-empty result, and fails loud
# (non-zero, no poisoned cache) on an empty/errored read. Caching is ON by default
# (BOARD_CACHE_TTL=90); export BOARD_CACHE_TTL=0 to force live reads.
#   board_item_list <board#>  ->  item-list JSON on stdout
board_item_list() {
  local _b; _b="$(board_resolve_name "$1")" || return 1; set -- "$_b" "${@:2}"
  if _board_is_issues_only "$1"; then
    _board_issues_item_list "$1"
    return $?
  fi
  _board_item_list_argv "$1"
  # Key the cache slot on the effective query: a non-default query reads a DIFFERENT
  # dataset, so it must NOT share the default slot (else the escape hatch would serve
  # the active-set page to a full-board reader, or vice versa, within the TTL). The
  # default query keeps the unchanged `items` slot; anything else gets its own.
  local kind=items
  [ "$_BOARD_IL_QUERY" = "-status:Done" ] || \
    kind="items-$(printf '%s' "$_BOARD_IL_QUERY" | tr -cs 'a-zA-Z0-9' '-')"
  # Capture first so _board_cached_read's fail-loud non-zero (GH #93: empty /
  # rate-limited read) propagates, THEN drop PR cards (#223). The on-disk cache
  # holds the RAW gh response (may include PR cards); every reader filters here,
  # so the cache stays generic — the asymmetry is inert (a valid {"items":[]}
  # still passes the jq filter unchanged, exit 0, same as before).
  local raw
  raw="$(_board_cached_read "$1" "$kind" "${_BOARD_IL_ARGV[@]}")" || return 1
  printf '%s' "$raw" | _board_sanitize_control_chars | _board_drop_pr_cards
}

# Resolve a single-select field's id by NAME from the cached field-list.
#   board_field_id <field-name>  ->  field id (empty if absent)
board_field_id() {
  printf '%s' "$BOARD_FIELDS_JSON" |
    jq -r --arg n "$1" '.fields[] | select(.name==$n) | .id'
}

# Resolve a single-select OPTION id by (field-name, option-name) from cache.
#   board_option_id <field-name> <option-name>  ->  option id (empty if absent)
board_option_id() {
  printf '%s' "$BOARD_FIELDS_JSON" |
    jq -r --arg f "$1" --arg o "$2" \
      '.fields[] | select(.name==$f) | .options[] | select(.name==$o) | .id'
}

# Resolve the board item id for an issue number from the cached item-list.
#   board_item_id <issue#>  ->  item id (empty if the issue is not on the board)
board_item_id() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .id'
}

# Resolve the issue title for an issue number from the cached item-list.
#   board_item_title <issue#>  ->  title (empty if absent)
board_item_title() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .content.title // ""'
}

# Resolve an item's release-phase milestone TITLE from the cached item-list.
# The release-phase axis rides GitHub's built-in, read-only `Milestone` field
# (foundation #97): a system field that can't be renamed/deleted, surfaced by
# `gh project item-list` as `.milestone = {title, description, dueOn}` on the
# Projects-v2 path, and — since temperloop#154 — carried as `.milestone = {title}`
# by the issues-only reshape (issue_item) too. Backend-agnostic on the read side:
# this bare `.milestone.title // ""` works on both. WRITES go through
# board_set_milestone (repo-level `gh issue edit`, since the board mirror is
# read-only).
#   board_item_milestone <issue#>  ->  milestone title (empty if none)
board_item_milestone() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .milestone.title // ""'
}

# Print the OPEN issues that block <issue#>, one number per line (empty output =
# not blocked). GitHub native issue *dependencies* (blocked_by) — a first-class
# relationship, separate from Status / labels / sub-issues. Reads the per-issue
# REST endpoint (NOT the Projects board / cache), so it is ALWAYS LIVE and costs
# one REST call per issue — REST's 5,000/hr bucket, separate from the Projects-v2
# GraphQL budget the board-page reads draw on. Callers MUST gate on candidate
# items only (a triage Backlog slice / a /next in-scope set), never the whole
# board. Emptiness is the gate; the numbers are returned so a caller can surface
# `blocked_by #M`. Pipes to an external `jq` (like board_resolve_item) so the
# `_board_gh` seam stays replay-testable.
#   board_blocked_by_open <board> <issue#>  ->  open-blocker numbers, one per line
board_blocked_by_open() {
  local board="$1" issue="$2" repo
  repo="$(board_repo "$board")" || return 1
  _board_gh api "repos/$repo/issues/$issue/dependencies/blocked_by" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.[] | select(.state=="open") | .number'
}

# Print the parent EPIC's issue number for a sub-issue, or empty for a singleton
# (foundation #159). The REST issue object has NO `.parent` key — the parent link
# is `.parent_issue_url` (e.g. ".../issues/145") and `.sub_issues_summary` is the
# issue's *own* children. Reading `.parent` therefore resolves empty for EVERY
# issue, silently mis-classifying every epic child as a parentless singleton — the
# exact bug this accessor exists to prevent. We parse the trailing number out of
# `.parent_issue_url` so the field name lives in ONE place (this adapter), mirroring
# board_blocked_by_open: per-issue REST endpoint (NOT the Projects board / cache),
# ALWAYS LIVE, one REST call (REST's 5,000/hr bucket, separate from the GraphQL
# board budget). Callers MUST gate on candidate items only, never the whole board.
# Empty output = no parent (a directly-workable singleton). Pipes to an external
# `jq` (like its siblings) so the `_board_gh` seam stays replay-testable.
#
# --- cache-relationships item (F#988 Contract) -------------------------------
# When `board.<N>.cache=on` AND the caller has separately sourced lib/cache.sh
# (same enable axis + `declare -F cache_read` probe as _board_issues_item_list's
# dispatch — see that function's PLANE MAP comment), this answers by INVERTING
# cache.sh's snapshot instead of paying a live per-issue REST call: the bulk
# snapshot row (`gh api repos/<r>/issues?state=all` shape, cache.sh's own
# storage format) carries the parent link as a nested `.parent.number` object —
# NOT the string `.parent_issue_url` the single-issue endpoint uses; these are
# two different GitHub REST shapes for the same relationship, so the cached arm
# reads `.parent.number` directly (no basename parsing needed) while the live
# arm below is unchanged. `cache_read` itself is the staleness-aware entrypoint
# (CACHE-STORE.md's degradation contract): warm-and-fresh serves straight off
# disk with ZERO gh calls; miss/stale pays exactly the ONE live refresh
# `cache_read` already does internally (this function does not layer a second
# live fallback on top of that — same convention as _board_issues_item_list).
# If the axis is on but cache.sh isn't in scope, one stderr notice and fall
# through to the always-live per-issue call, unchanged. board_blocked_by_open
# (above) deliberately has NO cached arm — native issue *dependencies* are a
# different relationship this item's scope excludes.
#   board_parent_issue <board> <issue#>  ->  parent epic number, or empty
board_parent_issue() {
  local board="$1" issue="$2" repo url raw parent
  repo="$(board_repo "$board")" || return 1
  if _board_cache_store_enabled "$board"; then
    if declare -F cache_read >/dev/null 2>&1; then
      raw="$(cache_read "$repo")" || return 1
      parent="$(printf '%s' "$raw" | _board_sanitize_control_chars | jq -s -r --argjson n "$issue" '
        .[] | select(.number == $n) | (.parent.number // empty)
      ')"
      [ -n "$parent" ] && printf '%s\n' "$parent"
      return 0
    fi
    echo "board: cache enabled for board $board (board.$board.cache=on) but lib/cache.sh is not sourced in this process — falling back to a live (uncached) read" >&2
  fi
  url="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.parent_issue_url // empty')"
  [ -n "$url" ] && basename "$url"
  return 0
}

# Print the CHILD (sub-issue) numbers of <issue#>, one per line (empty output
# = no children — a singleton, or an epic with none yet). The read-side
# counterpart to board_parent_issue, using GitHub's native sub-issues REST
# endpoint (foundation #800, claim/edges split). Works on a PLAIN issue with
# no Projects board provisioned — same per-issue REST shape as
# board_parent_issue / board_blocked_by_open (ALWAYS LIVE, REST's own
# 5,000/hr bucket, never the Projects-v2 GraphQL budget), so this is
# backend-agnostic for free: identical behavior whether <board> is
# Projects-v2-backed or issues-only. Callers MUST gate on candidate items
# only, never the whole board (same caveat as its siblings). Pipes to an
# external `jq` so the `_board_gh` seam stays replay-testable.
#
# --- cache-relationships item (F#988 Contract) -------------------------------
# Same cache-enabled check, same cache.sh delegation, and same fall-through-live
# degradation (one stderr notice) as board_parent_issue above — see its comment
# for the full contract. Inversion here selects every snapshot row whose
# `.parent.number` equals <issue#> and prints that row's OWN `.number`; the
# snapshot's ALL-states corpus (open AND closed — cache.sh never filters state,
# see CACHE-STORE.md) means a closed child is preserved here exactly as the live
# `/sub_issues` endpoint already includes closed children — no behavior change,
# just a cheaper read when warm.
#   board_sub_issues <board> <issue#>  ->  child issue numbers, one per line
board_sub_issues() {
  local board="$1" issue="$2" repo raw
  repo="$(board_repo "$board")" || return 1
  if _board_cache_store_enabled "$board"; then
    if declare -F cache_read >/dev/null 2>&1; then
      raw="$(cache_read "$repo")" || return 1
      printf '%s' "$raw" | _board_sanitize_control_chars | jq -s -r --argjson n "$issue" '
        .[] | select((.parent.number // empty) == $n) | .number
      '
      return $?
    fi
    echo "board: cache enabled for board $board (board.$board.cache=on) but lib/cache.sh is not sourced in this process — falling back to a live (uncached) read" >&2
  fi
  _board_gh api "repos/$repo/issues/$issue/sub_issues" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.[].number'
  return 0
}

# Guard: the project item-edit writers below are keyed by a PVTI_* item-id, NOT a
# board number or issue#. Called with the wrong arg shape (e.g. `board_set_status
# 489 "Done"`), the underlying gh item-edit fails opaquely — and because callers
# commonly swallow the exit code (`|| true` in best-effort bulk paths), a reported
# claim/status-flip silently no-ops (foundation #128: F103 "claimed In Progress"
# never took; #489 "Done" failed twice). Validate the arg shape up front and fail
# LOUD with a clear message, so the misuse surfaces even when the return code is
# swallowed. Resolve an item-id first with board_resolve_item / board_item_id.
_board_assert_item_id() {
  case "$1" in
    PVTI_* | ISSUE_*) return 0 ;;
    *)
      echo "board: ${2:-this op} needs a PVTI_* (Projects-v2) or ISSUE_* (issues-only) item-id as arg1 (got '$1') — resolve it first with board_resolve_item/board_item_id; a board number or issue# silently no-ops" >&2
      return 1 ;;
  esac
}

# Set the worklist single-select on an item to a named option.
#   board_set_status <item-id> <option-name> [field-name]
#     e.g. board_set_status PVTI_x "In Progress"            # default Status field
#          board_set_status PVTI_x "Backlog" "Some Field"   # explicit field override
# field-name defaults to BOARD_FIELD_STATUS (the built-in Status field every board
# governs on). The override arg remains for callers that target another
# single-select. Resolves the field id and the option id by name from cache, then
# issues the item-edit. Returns non-zero without editing if arg1 is not a PVTI_*
# item-id (foundation #128) or if either the field or option is missing.
board_set_status() {
  local item_id="$1" opt_name="$2" field_name="${3:-$BOARD_FIELD_STATUS}" status_field opt_id
  _board_assert_item_id "$item_id" board_set_status || return 1
  case "$item_id" in
    ISSUE_*)
      _board_issues_set_field "$item_id" "$field_name" "$opt_name"
      return $? ;;
  esac
  status_field="$(board_field_id "$field_name")"
  opt_id="$(board_option_id "$field_name" "$opt_name")"
  if [ -z "$status_field" ] || [ -z "$opt_id" ]; then
    return 1
  fi
  _board_gh project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
    --field-id "$status_field" --single-select-option-id "$opt_id" >/dev/null || return 1
  # Patch the one mutated field into the warm items page instead of busting it: a
  # single-select stores the option NAME under the flattened field key (GH #157).
  _board_cache_patch_field "$BOARD_CURRENT" "$item_id" "$field_name" \
    "$(printf '%s' "$opt_name" | jq -Rs .)"
}

# Set the board-native Component single-select on an item to a named option.
# Thin, intention-revealing wrapper over board_set_status's field-override arm
# (the Component axis is just another single-select). Returns non-zero without
# editing if the board has no Component field or no such option (the field is
# stageFind-seeded; not every board defines it).
#   board_set_component <item-id> <component-name>
board_set_component() {
  board_set_status "$1" "$2" "$BOARD_FIELD_COMPONENT"
}

# Stamp a free-text field on an item.
#   board_stamp <item-id> <field-name> <text>   (e.g. "Host/Session" "host:abc")
# Returns non-zero without editing if the field name does not resolve.
# An EMPTY <text> CLEARS the field: `gh project item-edit --text ''` errors with
# "no changes to make" (so a bare empty stamp was a silent no-op — foundation
# #259), so route the clear through `--clear` and null the cached key instead.
# This is what makes the build Step 5 epic park-back stamp-clear actually clear.
#
# ISSUE_* items (issues-only backend, foundation #800) route to
# _board_issues_stamp_field instead — a `fnd:<field-slug>:<verbatim-text>`
# label, single-value-per-prefix, empty text clears (same shape as the
# Projects-v2 --clear semantics above, no ISSUES-ONLY-BACKEND.md vocabulary
# change needed). This was the ONE function split #799 deliberately left
# failing loud ("out of scope for this split"); it is now implemented.
board_stamp() {
  local item_id="$1" field_name="$2" text="$3" field_id
  _board_assert_item_id "$item_id" board_stamp || return 1
  case "$item_id" in
    ISSUE_*)
      _board_issues_stamp_field "$item_id" "$field_name" "$text"
      return $? ;;
  esac
  field_id="$(board_field_id "$field_name")"
  if [ -z "$field_id" ]; then
    return 1
  fi
  if [ -z "$text" ]; then
    _board_gh project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
      --field-id "$field_id" --clear >/dev/null || return 1
    # Null the flattened field key in the warm page (matches a cleared field's
    # absence on the next live read), rather than busting the items cache.
    _board_cache_patch_field "$BOARD_CURRENT" "$item_id" "$field_name" "null"
    return 0
  fi
  _board_gh project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
    --field-id "$field_id" --text "$text" >/dev/null || return 1
  # Patch the new text under the flattened field key (Host/Session->host/Session)
  # rather than busting the warm items page (GH #157).
  _board_cache_patch_field "$BOARD_CURRENT" "$item_id" "$field_name" \
    "$(printf '%s' "$text" | jq -Rs .)"
}

# Assign an issue's release-phase milestone (foundation #97). The board's
# `Milestone` column is GitHub's read-only mirror of the issue's native milestone,
# so this writes at the REPO level (`gh issue edit … --milestone`) rather than via
# a board item-edit — keyed by issue NUMBER, not item id. Routes through the
# `_board_gh` seam (testable) and busts the board's item cache so the mirrored
# value re-reads fresh. The milestone must already exist in the repo (create it
# once with `gh api repos/<owner>/<repo>/milestones`). Returns non-zero (no edit)
# if the board number is unknown.
#   board_set_milestone <board#> <issue#> <milestone-title>
board_set_milestone() {
  local board="$1" issue="$2" title="$3" repo
  repo="$(board_repo "$board")" || return 1
  _board_gh issue edit "$issue" -R "$repo" --milestone "$title" >/dev/null || return 1
  _board_cache_bust "$board"
}

# Print the titles of the OPEN milestones marked "triage:active", one per line
# (foundation #210). A milestone is "active" iff its GitHub DESCRIPTION contains
# the literal HTML-comment marker `<!-- triage:active -->`; the default is
# inactive (no marker). The marker is MACHINE-OWNED — never hand-edited; written
# only via board_set_milestone_description (which the milestone.sh CLI verbs call
# in a later item). Milestones are read over REST (repos/<owner>/<repo>/milestones)
# NOT Projects-v2 GraphQL, keeping this off the scarce 5,000-pt/hr GraphQL budget
# (REST has its own separate 5,000/hr bucket). Routed through the `_board_gh` seam
# so the fixture-replay harness can stub it; pipes to an external `jq` like
# board_blocked_by_open / board_parent_issue so the seam stays replay-testable.
# Returns non-zero (no output) on an unknown board OR on an actual milestone-fetch
# failure — the API output is captured first (`|| return 1`) so a genuine REST
# error propagates instead of being masked by jq's exit code. A SUCCESSFUL fetch
# that finds zero active markers stays exit 0 with empty output: "none active" is
# the normal default state (milestones default inactive), NOT a failure. This lets
# a caller distinguish "fetch failed" (non-zero) from "genuinely none active"
# (exit 0, empty) — the disambiguation /triage's active-milestone guard needs
# (temperloop#152). Callers that only capture output (e.g. milestone.sh) are
# unaffected: an empty result reads the same either way.
#   board_active_milestones <board#>  ->  active milestone titles, one per line
board_active_milestones() {
  local board="$1" repo raw
  repo="$(board_repo "$board")" || return 1
  raw="$(_board_gh api "repos/$repo/milestones?state=open" 2>/dev/null)" || return 1
  printf '%s' "$raw" |
    _board_sanitize_control_chars |
    jq -r '.[] | select((.description // "") | contains("<!-- triage:active -->")) | .title'
}

# Set (overwrite) an OPEN milestone's GitHub description, resolving the milestone
# by TITLE (foundation #210). This is the WRITE half of the triage:active marker
# pair (board_active_milestones reads it): the milestone.sh CLI verbs call this to
# stamp/clear the machine-owned `<!-- triage:active -->` marker. Like its read
# sibling it goes over REST — a GET to resolve the title->number (and read the
# current description), then a PATCH of repos/<owner>/<repo>/milestones/<number> —
# NOT Projects-v2 GraphQL, so it never touches the GraphQL budget. Both calls route
# through the `_board_gh` seam (stubbable). IDEMPOTENT: if the milestone's current
# description already equals the target, it skips the PATCH (no-op, returns 0 — do
# not double-write). Fails loudly (non-zero, clear stderr) on an unknown board or
# an unknown milestone title.
#   board_set_milestone_description <board#> <title> <description>
board_set_milestone_description() {
  local board="$1" title="$2" desc="$3" repo number current
  repo="$(board_repo "$board")" || {
    echo "board: board_set_milestone_description — unknown board '$board'" >&2
    return 1
  }
  # Resolve the milestone by title over REST, capturing its number + current
  # description in one read (state=all so a closed milestone still resolves).
  local milestone_json
  milestone_json="$(
    _board_gh api "repos/$repo/milestones?state=all" 2>/dev/null |
      _board_sanitize_control_chars |
      jq -c --arg t "$title" 'map(select(.title == $t)) | .[0] // empty'
  )"
  if [ -z "$milestone_json" ]; then
    echo "board: board_set_milestone_description — no milestone titled '$title' in $repo" >&2
    return 1
  fi
  number="$(printf '%s' "$milestone_json" | jq -r '.number')"
  current="$(printf '%s' "$milestone_json" | jq -r '.description // ""')"
  # Idempotent: identical description -> skip the PATCH (no double-write).
  if [ "$current" = "$desc" ]; then
    return 0
  fi
  _board_gh api --method PATCH "repos/$repo/milestones/$number" \
    -f description="$desc" >/dev/null || return 1
}

# Set a number field on an item (e.g. the worklist `Seq` order).
#   board_set_number <item-id> <field-name> <value>   (e.g. "Seq" 3)
# Resolves the field id by name from cache, then issues the --number item-edit.
# Returns non-zero without editing if the field name does not resolve.
board_set_number() {
  local item_id="$1" field_name="$2" value="$3" field_id
  _board_assert_item_id "$item_id" board_set_number || return 1
  field_id="$(board_field_id "$field_name")"
  if [ -z "$field_id" ]; then
    return 1
  fi
  _board_gh project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
    --field-id "$field_id" --number "$value" >/dev/null || return 1
  # Patch the new number under the flattened field key (Seq->seq) rather than
  # busting the warm items page (GH #157). Normalize via jq so the cache stores a
  # JSON number (matching gh item-list's shape); a non-numeric value can't reach
  # here (the item-edit --number above would have failed first), but if jq still
  # rejects it, _board_cache_patch_field falls back to the safe whole-page bust.
  local json_value
  json_value="$(jq -n --arg v "$value" '$v | tonumber' 2>/dev/null)" || json_value=""
  if [ -n "$json_value" ]; then
    _board_cache_patch_field "$BOARD_CURRENT" "$item_id" "$field_name" "$json_value"
  else
    _board_cache_bust
  fi
}

# Add an existing issue URL to a board (does NOT set Status; caller follows
# with board_resolve + board_set_status to land it in Backlog).
#   board_add_to_board <board#> <issue-url>
board_add_to_board() {
  _board_gh project item-add "$(board_project_number "$1")" --owner "$(board_owner "$1")" --url "$2" >/dev/null || return 1
  _board_cache_bust "$1"
}

# Add many already-created issues to a board and land each in Backlog, paying a
# SINGLE board_resolve for the WHOLE batch instead of one resolve per item.
#
# This is the BURST path for /triage and /build, which create N issues/epics
# at once. Calling board_create_on_board in a loop re-resolved the whole board
# (project view + field-list + the item-list active-set page, plus up to 3 more
# item-list fetches in the index-retry) on EVERY item — O(N) full re-lists of an
# expensive paginated Projects-v2 GraphQL query, which drained the 5,000-pt/hr
# budget mid-run (GH #40). Here the whole batch costs ONE board_resolve plus a
# bounded index-retry whose re-list is SHARED across all still-missing items, so
# the GraphQL cost is independent of N.
#
# The issues already exist (gh issue create is repo-level, not board state, so it
# stays in the caller). Projects-v2 indexes a newly-added item asynchronously:
# the item-list inside the first board_resolve often does NOT yet contain a
# just-added item (GH #386), so after adding all URLs we resolve once and then,
# while ANY item is still missing, re-fetch the item-list (a single shared
# active-set page per attempt, never per item) a few times. The client-side
# Backlog set is the load-bearing no-untracked-item guarantee (GH #387) — board 3
# has a server-side 'Item added -> Backlog' workflow, but not every board does.
# An item that never indexes WARNs on stderr (no silent unstatused add); the
# batch still returns 0 so a caller's success line still prints.
#   board_create_many <board#> <url1> <num1> [<url2> <num2> ...]
board_create_many() {
  local board="$1"; shift
  if _board_is_issues_only "$board"; then
    _board_issues_create_many "$board" "$@"
    return $?
  fi
  local url num attempt item_id missing max_attempts
  local nums=()
  # Index-lag retry budget. Projects-v2 can take longer than a few seconds to
  # index a just-added item; too small a budget leaves laggards unstatused (the
  # observed 2026-06-21 friction: 3 of 8 new items unstatused because the old
  # 3-attempt / ~6s window elapsed before GitHub indexed them). Default 5 with a
  # graduated backoff (~2+3+4+5 = 14s worst case). Overridable for tuning/tests.
  max_attempts="${BOARD_CREATE_INDEX_RETRIES:-5}"
  # 1) item-add every URL (each a cheap single-node mutation).
  while [ "$#" -ge 2 ]; do
    url="$1"; num="$2"; shift 2
    board_add_to_board "$board" "$url"
    nums+=("$num")
  done
  [ "${#nums[@]}" -gt 0 ] || return 0
  # 2) ONE resolve, then a bounded retry that re-lists ONCE per attempt for the
  #    whole batch (not per item) until every added item indexes.
  board_resolve "$board"
  for attempt in $(seq 1 "$max_attempts"); do
    missing=0
    for num in "${nums[@]}"; do
      if [ -z "$(board_item_id "$num")" ]; then missing=1; fi
    done
    if [ "$missing" -eq 0 ]; then break; fi
    # Graduated backoff: give GitHub progressively more time to index laggards.
    sleep "$((attempt + 1))"
    # Read FRESH: a cached page would hide the just-added items we're waiting on.
    BOARD_ITEMS_JSON="$(_board_item_list_fresh "$board")"
  done
  # 3) set Backlog on each item that resolved; warn (don't fail) on the rest.
  for num in "${nums[@]}"; do
    item_id="$(board_item_id "$num")"
    if [ -n "$item_id" ]; then
      # Every board governs on the built-in Status field (board_set_status default).
      board_set_status "$item_id" "$BOARD_OPT_BACKLOG" || true
    else
      echo "warning: #$num added to board $board but its item id did not resolve" \
           "in time to set Backlog; it may be unstatused on the board" >&2
    fi
  done
}

# Single-item convenience wrapper over board_create_many (the capture.sh flow:
# one issue already created repo-side; item-add it and land it in Backlog). For a
# burst of items prefer board_create_many directly — it resolves the board once
# for the whole batch instead of once per item (GH #40).
#   board_create_on_board <board#> <issue-url> <issue#>
board_create_on_board() {
  board_create_many "$1" "$2" "$3"
}

# --- auto-add-aware single-item placement (GH #53) ------------------------
# When the board's built-in "Auto-add to project" workflow is ON, a freshly
# created issue lands on the board on its own — so the explicit item-add +
# whole-board resolve board_create_on_board does is redundant, and that resolve
# is exactly the Projects-v2 GraphQL cost GH #53 is about.
#
# This places a just-created issue the CHEAP way: poll the single-item resolve
# (board_resolve_item — no whole-board item-list) a few times for auto-add to
# index it; once it appears, ensure it's in Backlog (covers a board whose
# auto-add adds membership but does NOT set Status); and only if it NEVER appears
# fall back to the explicit board_create_on_board. So the expensive add becomes
# the rare fallback, not the default — and the result is correct whether or not
# auto-add (and an "Item added -> Backlog" workflow) is configured.
#
# NOTE: only a net win once auto-add is enabled on the board; with it OFF every
# call burns the poll attempts before falling back. Enable auto-add first.
#   board_capture_item <board#> <issue-url> <issue#>
board_capture_item() {
  # NB: 'item_status', not 'status' — 'status' is zsh's read-only alias for $?,
  # and the Claude Code Bash tool sources this adapter under zsh; a 'local status'
  # there dies with "read-only variable: status" (foundation #82).
  local board="$1" url="$2" num="$3" attempt item_id item_status
  for attempt in 1 2 3; do
    board_resolve_item "$board" "$num"
    item_id="$(board_item_id "$num")"
    if [ -n "$item_id" ]; then
      item_status="$(
        printf '%s' "$BOARD_ITEMS_JSON" |
          jq -r --argjson n "$num" '.items[] | select(.content.number==$n) | .status // ""'
      )"
      # Auto-add placed it; land it in Backlog only if it isn't already statused.
      [ -n "$item_status" ] || board_set_status "$item_id" "$BOARD_OPT_BACKLOG" || true
      return 0
    fi
    sleep 2
  done
  # Auto-add never indexed the issue — fall back to the explicit add.
  board_create_on_board "$board" "$url" "$num"
}
