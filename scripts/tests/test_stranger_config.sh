#!/usr/bin/env bash
#
# test_stranger_config.sh — the stranger-config test (foundation #779, Epic A
# #762 "kernel seams"). Epic A's PRs (#785 boards.conf registry, #782/#788/#789
# knowledge_store interface + obsidian adapter + knowledge_search, #783 tracker
# seam config, #784 quality-gates kernel/overlay split, #786 XDG install paths,
# #790/#791 caller-routing) each landed one config seam so a non-Towheads
# adopter's kernel-only install can run this repo's pipeline with none of
# Travis's org/repo/operator/vault literals baked in. This is the first test
# that builds a FULL synthetic non-Towheads identity — fake owner/repo/project
# number, non-default KNOWLEDGE_STORE_ROOT, non-default FUNNEL_OPERATOR /
# FUNNEL_REQUIRED_CHECK — and drives every seam through it AT ONCE, proving the
# seams compose rather than just each surviving its own single-axis unit test.
#
# Zero network, zero live `gh`/`claude` — every board/funnel-tick/funnel-drive
# path below is either --dry-run or driven against a mocked FUNNEL_GH_BIN
# double (the same test-injection idiom test_funnel_drive.sh already uses for
# its #718 reconciliation-probe tests). Real $HOME, real ~/dev/mind, and real
# ~/.claude are never read or written — every path below resolves under a
# throwaway tmpdir standing in for a stranger's fresh $HOME/XDG layout.
#
# Sections:
#   A. sandbox setup — synthetic stranger identity (board 42 -> a fake
#      owner/repo/project via boards.conf; fake $HOME/XDG; non-default
#      KNOWLEDGE_STORE_ROOT/FUNNEL_OPERATOR/FUNNEL_REQUIRED_CHECK)
#   B. regression baseline — the existing board suite (test_boards_conf.sh)
#      and the existing knowledge_store suite (test_knowledge_store.sh) still
#      pass, unmodified, run in a clean subshell with none of this file's
#      stranger env leaked in (partial-conf coexistence, #770's guarantee)
#   C. board.sh: board_repo/board_owner/board_project_number resolve the
#      stranger identity for board 42, and built-in boards 3-6 are unaffected
#   D. funnel-tick.sh --dry-run under the stranger config: every emitted
#      action's repo is the stranger repo, drain-parse-miss reassigns the
#      stranger operator, and the raw plan JSON carries no "Towheads" or
#      "@towhead" literal
#   E. funnel-drive.sh --dry-run tiering: the stranger repo passes through the
#      safe/merge tiering untouched, no Towheads substituted
#   F. funnel-drive.sh's _board_repo mirror (the #718 reconciliation probe,
#      exercised via a mocked FUNNEL_GH_BIN double — never live gh) resolves
#      board 42 to the stranger repo, not the built-in Towheads/stageFind
#   G. knowledge_store.sh: ks_root/ks_write/ks_read/ks_list round-trip under
#      a non-default KNOWLEDGE_STORE_ROOT, never touching the real vault
#   H. knowledge_search.sh binds to the same ks_root (no independent corpus
#      path) and its BM_HOME resolves under the stranger XDG_STATE_HOME
#   I. build.config.sh: an exported stranger KNOWLEDGE_STORE_ROOT /
#      FUNNEL_OPERATOR / FUNNEL_REQUIRED_CHECK survive sourcing (the `:=`
#      idiom means the file's own foundation-specific defaults never win)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

BOARD_LIB="$REPO_ROOT/workflows/scripts/board/lib/board.sh"
TICK="$REPO_ROOT/workflows/scripts/build/funnel-tick.sh"
DRIVE="$REPO_ROOT/workflows/scripts/build/funnel-drive.sh"
BUILD_CONFIG="$REPO_ROOT/workflows/scripts/build/build.config.sh"
KS_LIB="$REPO_ROOT/workflows/scripts/lib/knowledge_store.sh"
KS_SEARCH_LIB="$REPO_ROOT/workflows/scripts/lib/knowledge_search.sh"
BOARDS_CONF_TEST="$REPO_ROOT/workflows/scripts/board/tests/test_boards_conf.sh"
KS_TEST="$REPO_ROOT/workflows/scripts/lib/tests/test_knowledge_store.sh"

for f in "$BOARD_LIB" "$TICK" "$DRIVE" "$BUILD_CONFIG" "$KS_LIB" "$KS_SEARCH_LIB" "$BOARDS_CONF_TEST" "$KS_TEST"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stranger-config-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Hermeticity: neutralize any host-local build.config.local.sh (#1055) ─────
# build.config.sh (sourced by funnel-tick.sh/funnel-drive.sh, and directly in
# Section I) sources $BUILD_CONFIG_LOCAL when it exists — its documented test
# seam. On a developer's PRIMARY checkout that sibling file is present and
# hard-`export`s a real FUNNEL_OPERATOR (@towhead), which leaks past the injected
# STRANGER_OPERATOR and fails Section D's reassign assertion (`got towhead`). A
# fresh checkout / CI has no such file and passes, so the break only surfaces
# on a real dev machine. Point the seam at a guaranteed-absent path so no
# host-local config is ever sourced, keeping the test hermetic regardless of the
# running checkout. Exported so every subshell (the funnel-tick / build.config
# invocations below) inherits it.
export BUILD_CONFIG_LOCAL="$WORK/no-such-local-config.sh"

# ── A: synthetic stranger identity ──────────────────────────────────────────
# Board 42 is NOT one of the built-in boards (3/4/5/6) — a genuinely new board
# number, not an override of an existing one, so a mis-resolution to the
# built-in map is unambiguous (it would either fail outright or leak a
# Towheads/* value neither this conf nor the built-in map for 42 provides).
STRANGER_REPO="acme-widgets/gadget-tracker"
STRANGER_OWNER="acme-widgets"
STRANGER_PROJECT="17"
STRANGER_OPERATOR="@widget-ops"
STRANGER_CHECK="ci-required"

mkdir -p "$WORK/home/.config/foundation" "$WORK/home/.local/share" "$WORK/home/.local/state"
STRANGER_HOME="$WORK/home"
STRANGER_KS_ROOT="$WORK/knowledge-root"

cat > "$WORK/boards.conf" <<EOF
board.42.repo=$STRANGER_REPO
board.42.owner=$STRANGER_OWNER
board.42.project=$STRANGER_PROJECT
EOF
NO_MACHINE_CONF="$WORK/no-such-machine-conf"

echo "=== Section B: regression baseline (existing suites, unmodified) ==="

# ── B1: the existing board suite still passes, run in a clean subshell with
# NONE of this file's stranger env exported — proves the stranger identity
# built above is additive, never a global mutation. ─────────────────────────
if ( unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL; bash "$BOARDS_CONF_TEST" >/dev/null 2>&1 ); then
  ok "B1: test_boards_conf.sh (existing board-conf suite) still passes clean"
else
  bad "B1" "test_boards_conf.sh failed in a clean subshell"
fi

# ── B2: the existing knowledge_store suite still passes clean. ─────────────
if ( unset KNOWLEDGE_STORE_ROOT; bash "$KS_TEST" >/dev/null 2>&1 ); then
  ok "B2: test_knowledge_store.sh (existing knowledge_store suite) still passes clean"
else
  bad "B2" "test_knowledge_store.sh failed in a clean subshell"
fi

echo "=== Section C: board.sh resolves the stranger identity (board 42) ==="

BOARD_OUT="$(
  export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
  export BOARDS_CONF_MACHINE="$NO_MACHINE_CONF"
  # shellcheck source=/dev/null
  source "$BOARD_LIB"
  printf 'repo42=%s\n'  "$(board_repo 42)"
  printf 'owner42=%s\n' "$(board_owner 42)"
  printf 'proj42=%s\n'  "$(board_project_number 42)"
  printf 'repo3=%s\n'   "$(board_repo 3)"
  printf 'repo4=%s\n'   "$(board_repo 4)"
  printf 'owner3=%s\n'  "$(board_owner 3)"
)"

get() { printf '%s\n' "$BOARD_OUT" | sed -n "s/^$1=//p"; }

[ "$(get repo42)" = "$STRANGER_REPO" ] && ok "C: board_repo 42 resolves the stranger repo from boards.conf" \
  || bad "C.repo42" "got $(get repo42)"
[ "$(get owner42)" = "$STRANGER_OWNER" ] && ok "C: board_owner 42 resolves the stranger owner" \
  || bad "C.owner42" "got $(get owner42)"
[ "$(get proj42)" = "$STRANGER_PROJECT" ] && ok "C: board_project_number 42 resolves the stranger project number" \
  || bad "C.proj42" "got $(get proj42)"
[ "$(get repo3)" = "Towheads/stageFind" ] && ok "C: board 3 (built-in, not in conf) still falls back unaffected" \
  || bad "C.repo3" "got $(get repo3)"
[ "$(get repo4)" = "Towheads/foundation" ] && ok "C: board 4 (built-in, not in conf) still falls back unaffected" \
  || bad "C.repo4" "got $(get repo4)"
[ "$(get owner3)" = "Towheads" ] && ok "C: board_owner 3 still falls back unaffected" \
  || bad "C.owner3" "got $(get owner3)"

echo "=== Section D: funnel-tick.sh --dry-run under the stranger config ==="

FX="$WORK/fixture"
mkdir -p "$FX/board-42"
cat > "$FX/board-42/ready.json" <<'JSON'
[{"number":9001,"title":"widget conveyor jam","labels":[]}]
JSON
cat > "$FX/board-42/decisions.json" <<'JSON'
[{"number":9002,"title":"gearing ratio","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"whatever works"}]}]
JSON
echo 0 > "$FX/board-42/assignees-9002.txt"

TICK_PLAN="$(
  BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf" \
  BOARDS_CONF_MACHINE="$NO_MACHINE_CONF" \
  FUNNEL_ENABLED_BOARDS=42 \
  FUNNEL_OPERATOR="$STRANGER_OPERATOR" \
  bash "$TICK" --dry-run --fixture "$FX" --board 42
)"

if [ -z "$TICK_PLAN" ] || ! jq -e . >/dev/null 2>&1 <<<"$TICK_PLAN"; then
  bad "D.parse" "funnel-tick.sh did not emit valid JSON: $TICK_PLAN"
else
  [ "$(jq -r '.dry_run' <<<"$TICK_PLAN")" = "true" ] && ok "D: dry_run flag set" \
    || bad "D.dry_run" "got $(jq -r '.dry_run' <<<"$TICK_PLAN")"

  N_ACTIONS="$(jq '.actions | length' <<<"$TICK_PLAN")"
  [ "${N_ACTIONS:-0}" -gt 0 ] && ok "D: tick emitted actions ($N_ACTIONS)" || bad "D.count" "no actions emitted"

  ALL_REPOS="$(jq -r '[.actions[].repo] | unique | .[]' <<<"$TICK_PLAN")"
  [ "$ALL_REPOS" = "$STRANGER_REPO" ] && ok "D: every action's repo is the stranger repo (board-repo mirror resolved from registry)" \
    || bad "D.repo" "got: $ALL_REPOS"

  MISS="$(jq -c 'first(.actions[] | select(.action=="drain-parse-miss"))' <<<"$TICK_PLAN")"
  [ -n "$MISS" ] && [ "$MISS" != "null" ] && ok "D: drain-parse-miss produced" || bad "D.miss" "no drain-parse-miss action: $TICK_PLAN"
  # reassign_to is the BARE login — the leading `@` of FUNNEL_OPERATOR is stripped
  # for the `--add-assignee` target (foundation #977); the `@` is kept only for
  # mention/config-resolution (asserted separately below on the build.config.sh output).
  [ "$(jq -r '.reassign_to' <<<"$MISS")" = "${STRANGER_OPERATOR#@}" ] && ok "D: parse-miss reassigns the stranger FUNNEL_OPERATOR (bared, #977)" \
    || bad "D.reassign" "got $(jq -r '.reassign_to // "MISSING"' <<<"$MISS")"

  DRIVE_ACT="$(jq -c 'first(.actions[] | select(.action=="drive-ready"))' <<<"$TICK_PLAN")"
  [ -n "$DRIVE_ACT" ] && [ "$DRIVE_ACT" != "null" ] && ok "D: drive-ready produced for the unlabeled Ready item" \
    || bad "D.drive" "no drive-ready action: $TICK_PLAN"

  if printf '%s' "$TICK_PLAN" | grep -qi "towheads"; then
    bad "D.leak" "plan JSON leaks a Towheads/* literal: $TICK_PLAN"
  else
    ok "D: no residual 'Towheads' literal anywhere in the tick plan"
  fi
  if printf '%s' "$TICK_PLAN" | grep -q "@towhead"; then
    bad "D.op-leak" "plan JSON leaks the default @towhead operator literal: $TICK_PLAN"
  else
    ok "D: no residual '@towhead' default-operator literal (stranger operator used throughout)"
  fi
fi

echo "=== Section E: funnel-drive.sh --dry-run tiering carries the stranger repo through ==="

STRANGER_TIER_PLAN="$(jq -cn --arg r "$STRANGER_REPO" '[{"tick":"done","actions":[
  {"phase":"drain","action":"drain-answer","board":"42","repo":$r,"issue":9002,"chosen":"chosen-x"},
  {"phase":"drive","action":"drive-ready","board":"42","repo":$r,"issue":9003,"kind":"spike","emit":"/assess"}
]}]')"

DRIVE_DRY_OUT="$(printf '%s' "$STRANGER_TIER_PLAN" | env FUNNEL_GH_BIN="/usr/bin/false" bash "$DRIVE" --dry-run)"

if [ -z "$DRIVE_DRY_OUT" ] || ! jq -e . >/dev/null 2>&1 <<<"$DRIVE_DRY_OUT"; then
  bad "E.parse" "funnel-drive.sh --dry-run did not emit valid JSON: $DRIVE_DRY_OUT"
else
  [ "$(jq -r '.status' <<<"$DRIVE_DRY_OUT")" = "dry-run" ] && ok "E: status=dry-run (no claude spawn)" \
    || bad "E.status" "got $(jq -r '.status' <<<"$DRIVE_DRY_OUT")"
  SAFE_REPOS="$(jq -r '[.safe[].repo] | unique | .[]?' <<<"$DRIVE_DRY_OUT")"
  [ "$(jq '.safe | length' <<<"$DRIVE_DRY_OUT")" -gt 0 ] && [ "$SAFE_REPOS" = "$STRANGER_REPO" ] \
    && ok "E: safe-tier actions carry the stranger repo through untouched" \
    || bad "E.safe-repo" "got: $SAFE_REPOS (safe count $(jq '.safe | length' <<<"$DRIVE_DRY_OUT"))"
  if printf '%s' "$DRIVE_DRY_OUT" | grep -qi "towheads"; then
    bad "E.leak" "dry-run tiering output leaks a Towheads/* literal: $DRIVE_DRY_OUT"
  else
    ok "E: no residual 'Towheads' literal in the dry-run tiering output"
  fi
fi

echo "=== Section F: funnel-drive.sh's _board_repo mirror (mocked gh, #718 reconcile probe) ==="

# A single kind:code drive so n_safe=0 (code never lands in the safe tier) and,
# with FUNNEL_DRIVE_MERGE left at its default-off, do_merge=0 too -> the
# "empty" fast path runs _reconcile_pending, which is the ONE place
# funnel-drive.sh's own _board_repo mirror actually resolves a repo (dry-run
# skips reconciliation entirely, so this mocked-gh live-but-offline path is
# how the mirror itself gets exercised, per test_funnel_drive.sh's existing
# #718 test idiom — never real gh, never network).
CODE_PLAN='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"42","repo":"whatever/ignored","issue":9010,"kind":"code","emit":"/build"}]}]'

CAP="$WORK/gh-cap"
mkdir -p "$CAP"
GH_DOUBLE="$CAP/gh.sh"
cat > "$GH_DOUBLE" <<'GHDOUBLE'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${GH_PENDING_JSON:-[]}"
  exit 0
fi
printf '%s\n' "$*" >> "$CAP_DIR/gh-calls.txt"
exit 0
GHDOUBLE
chmod +x "$GH_DOUBLE"

RECONCILE_OUT="$(
  printf '%s' "$CODE_PLAN" | env \
    FUNNEL_GH_BIN="$GH_DOUBLE" CAP_DIR="$CAP" \
    BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf" BOARDS_CONF_MACHINE="$NO_MACHINE_CONF" \
    GH_PENDING_JSON='[{"number":9010,"state":"CLOSED"}]' \
    bash "$DRIVE"
)"

[ "$(jq -r '.status' <<<"$RECONCILE_OUT")" = "empty" ] && ok "F: empty fast path taken (n_safe=0, merge gate off)" \
  || bad "F.status" "got $(jq -r '.status // "PARSE-FAIL"' <<<"$RECONCILE_OUT")"
[ "$(jq -r '.reconciled_merged' <<<"$RECONCILE_OUT")" = "1" ] && ok "F: reconciliation probe ran (_board_repo was called)" \
  || bad "F.reconciled" "got $(jq -r '.reconciled_merged // "PARSE-FAIL"' <<<"$RECONCILE_OUT")"

if [ -f "$CAP/gh-calls.txt" ] && grep -qx "issue edit 9010 -R $STRANGER_REPO --remove-label funnel-merge-pending" "$CAP/gh-calls.txt"; then
  ok "F: _board_repo resolved board 42 to the stranger repo (not the built-in Towheads/stageFind)"
else
  bad "F.repo" "got: $(cat "$CAP/gh-calls.txt" 2>/dev/null || echo 'no gh-calls.txt')"
fi

echo "=== Section G: knowledge_store.sh round-trips under a stranger KNOWLEDGE_STORE_ROOT ==="

KS_OUT="$(
  export KNOWLEDGE_STORE_ROOT="$STRANGER_KS_ROOT"
  export HOME="$STRANGER_HOME"
  # Pin the read-log (temperloop#229) into the stranger sandbox: HOME is
  # overridden above, but an inherited XDG_STATE_HOME from the outer
  # environment would otherwise win the log path's default and leak test
  # entries into the real machine's state dir.
  export XDG_STATE_HOME="$STRANGER_HOME/.local/state"
  # shellcheck source=/dev/null
  source "$KS_LIB"
  root="$(ks_root)"
  printf 'root=%s\n' "$root"
  printf 'widget note content\n' | ks_write "Decisions/widget-choice" 2>&1
  printf 'write_rc=%s\n' "$?"
  ks_read "Decisions/widget-choice" 2>&1
  printf 'read_rc=%s\n' "$?"
  ks_list "Decisions" 2>&1
)"

printf '%s\n' "$KS_OUT" | grep -qx "root=$STRANGER_KS_ROOT" && ok "G: ks_root resolves the stranger KNOWLEDGE_STORE_ROOT" \
  || bad "G.root" "got: $KS_OUT"
printf '%s\n' "$KS_OUT" | grep -qx "widget note content" && ok "G: ks_write/ks_read round-trip content under the stranger root" \
  || bad "G.roundtrip" "got: $KS_OUT"
printf '%s\n' "$KS_OUT" | grep -qx "Decisions/widget-choice.md" && ok "G: ks_list finds the written doc-id under the stranger root" \
  || bad "G.list" "got: $KS_OUT"

if [ -d "$STRANGER_HOME/dev/mind" ]; then
  bad "G.vault-touch" "the stranger run created $STRANGER_HOME/dev/mind — a real-vault-shaped path should never be touched when KNOWLEDGE_STORE_ROOT is overridden"
else
  ok "G: no vault-shaped path (\$HOME/dev/mind) was created under the stranger sandbox"
fi

echo "=== Section H: knowledge_search.sh binds to the same ks_root + stranger XDG_STATE_HOME ==="

KS_SEARCH_OUT="$(
  export KNOWLEDGE_STORE_ROOT="$STRANGER_KS_ROOT"
  export XDG_STATE_HOME="$STRANGER_HOME/.local/state"
  export HOME="$STRANGER_HOME"
  # shellcheck source=/dev/null
  source "$KS_LIB"
  # shellcheck source=/dev/null
  source "$KS_SEARCH_LIB"
  # _ks_bm_home is the resolution accessor (KNOWLEDGE_SEARCH_BM_HOME itself
  # is only assigned lazily, inside it, on first call -- mirroring the
  # ks_root lazy-assign-on-call shape).
  printf 'bm_home=%s\n' "$(_ks_bm_home)"
  ks_search_available >/dev/null 2>&1
  printf 'available_rc=%s\n' "$?"
)"

WANT_BM_HOME="$STRANGER_HOME/.local/state/foundation/basic-memory-home"
printf '%s\n' "$KS_SEARCH_OUT" | grep -qx "bm_home=$WANT_BM_HOME" && ok "H: KNOWLEDGE_SEARCH_BM_HOME resolves under the stranger XDG_STATE_HOME" \
  || bad "H.bmhome" "got: $KS_SEARCH_OUT (want bm_home=$WANT_BM_HOME)"
AVAIL_RC="$(printf '%s\n' "$KS_SEARCH_OUT" | sed -n 's/^available_rc=//p')"
case "$AVAIL_RC" in
  0|3) ok "H: ks_search_available degrades legibly offline (rc=$AVAIL_RC: 0=present, 3=skipped — never crashes, never a network call)" ;;
  *)   bad "H.available" "unexpected rc=$AVAIL_RC" ;;
esac

echo "=== Section I: build.config.sh — stranger overrides win over its own foundation-specific defaults ==="

BUILD_CFG_OUT="$(
  BUILD_CONFIG_LOCAL="$WORK/no-such-local.sh" \
  KNOWLEDGE_STORE_ROOT="$STRANGER_KS_ROOT" \
  FUNNEL_OPERATOR="$STRANGER_OPERATOR" \
  FUNNEL_REQUIRED_CHECK="$STRANGER_CHECK" \
  bash -c '. "$1"; printf "root=%s\nop=%s\ncheck=%s\n" "$KNOWLEDGE_STORE_ROOT" "$FUNNEL_OPERATOR" "$FUNNEL_REQUIRED_CHECK"' _ "$BUILD_CONFIG"
)"

printf '%s\n' "$BUILD_CFG_OUT" | grep -qx "root=$STRANGER_KS_ROOT" \
  && ok "I: KNOWLEDGE_STORE_ROOT override survives build.config.sh (not overwritten to \$HOME/dev/mind)" \
  || bad "I.root" "got: $BUILD_CFG_OUT"
printf '%s\n' "$BUILD_CFG_OUT" | grep -qx "op=$STRANGER_OPERATOR" \
  && ok "I: FUNNEL_OPERATOR override survives build.config.sh (not overwritten to @towhead)" \
  || bad "I.op" "got: $BUILD_CFG_OUT"
printf '%s\n' "$BUILD_CFG_OUT" | grep -qx "check=$STRANGER_CHECK" \
  && ok "I: FUNNEL_REQUIRED_CHECK override survives build.config.sh" \
  || bad "I.check" "got: $BUILD_CFG_OUT"

echo
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  echo "FAIL: test_stranger_config.sh"
  exit 1
fi
echo "ALL PASS: test_stranger_config.sh"
