#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/board-mirror.sh — the build
# board-mirror entrypoints (epic #253, spike #245). These mirror the SAME
# fixture system the board toolkit tests use: ONE seam, the `gh` binary, is
# stubbed on PATH. board.sh routes every board call through `_board_gh() { gh
# "$@"; }`, so a PATH `gh` stub IS the `_board_gh` override — and it also covers
# the nested claim.sh / capture.sh subprocesses board-mirror shells out to. Zero
# network; structured-output assertions via jq.
#
# The stub is a programmable router: a STATE dir holds fixture JSON the stub
# reads (issue state, sub-issues, search hits) and a LOG file recording every
# mutating call so the tests can assert what was (and was NOT) issued — exactly
# how test_claim.sh records item-edits.
#
# Covers all six mapped steps + their idempotency:
#   2.5 ensure-issue : create-if-missing (back-link probe in:body); reuse on hit
#   2.6 ensure-epic  : link unlinked children; SKIP already-linked (idempotent);
#                      warn-and-continue on one linkage failure
#   3a  claim-item   : contention HALT under a foreign live stamp; CLAIMED +
#                      epic moved In Progress on first claim
#   4d-epic close-epic: closes at open-children==0; no-op on already-closed
#                       (idempotent); no close while children open
#   4d-retro file-retro: files one spike retro on --just-closed; RETRO_EXISTS
#                        when the body-marker already present (idempotent)
#   Step-5 park-epic : parks our own In-Progress epic -> Ready + clears stamp;
#                      PARK_FOREIGN leaves a different session's stamp untouched
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/board-mirror.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Keep the board cache off the real dir + force live reads (no stale page).
export BOARD_CACHE_DIR="$TMP/cache"; mkdir -p "$BOARD_CACHE_DIR"
export BOARD_CACHE_TTL=0
# Isolate from any host-level boards.conf (machine, legacy ~/.config/foundation,
# or repo-local) so board 4 resolves to its built-in default (projects backend,
# project #3). A real dev-host boards.conf carrying `board.4.backend=issues`
# (the temperloop#460 fleet-cutover soak) would otherwise flip board 4 onto the
# issues-only resolve path this projects-fixtured suite does not stub, so the
# 3a contention pre-check reads an unstamped default issue and never HALTS —
# green in CI (clean host, no conf), red on a dev host. temperloop#592.
export BOARDS_CONF_MACHINE="$TMP/no-machine.conf"     # nonexistent -> no machine/legacy conf
export BOARDS_CONF_REPO_LOCAL="$TMP/no-repo.conf"     # nonexistent -> no repo-local conf
# Deterministic claim stamp; never inside tmux (skip claim.sh's marker block).
export SUBSET_HOST_LABEL="testhost"
export CLAUDE_CODE_SESSION_ID="sess1234deadbeef"   # -> stamp "testhost:sess1234"
unset TMUX || true

# --- the programmable gh stub on PATH -----------------------------------------
# A STATE dir of fixture files the stub reads; a LOG of mutating calls.
STATE="$TMP/state"; mkdir -p "$STATE"
export BM_STATE="$STATE"
LOG="$TMP/gh.log"; export BM_LOG="$LOG"
: >"$LOG"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Programmable gh stub. Routes the calls board.sh + board-mirror.sh make. Reads
# fixtures from $BM_STATE; appends mutating calls to $BM_LOG.
set -euo pipefail
log() { printf '%s\n' "$*" >>"$BM_LOG"; }
S="$BM_STATE"

# Flatten args for matching, and pull out a few we key on.
all="$*"

case "${1:-}" in
  api)
    shift
    # find a jq filter if present (--jq X) and the method
    method="GET"; jqf=""; path=""; post_id=""
    args=("$@")
    i=0
    while [ $i -lt ${#args[@]} ]; do
      a="${args[$i]}"
      case "$a" in
        --method) i=$((i+1)); method="${args[$i]}" ;;
        -X)       i=$((i+1)); method="${args[$i]}" ;;
        --jq)     i=$((i+1)); jqf="${args[$i]}" ;;
        -f|-F)    i=$((i+1)); kv="${args[$i]}"
                  case "$kv" in sub_issue_id=*) post_id="${kv#sub_issue_id=}" ;; esac ;;
        graphql)  : ;;
        -*)       : ;;
        *)        [ -z "$path" ] && path="$a" ;;
      esac
      i=$((i+1))
    done

    # board_resolve_item's GraphQL query. The fixture ($S/resolve_item.json) is
    # the CONVENIENT pre-reshaped item-list form ({items:[{id,content,status,
    # host/Session}]}); board_resolve_item's jq expects the RAW GraphQL response,
    # so synthesize that shape here from the fixture. -F num pins which issue the
    # query is "for" (multi-item fixtures resolve the matching one). This keeps
    # the test fixtures readable while exercising the adapter's real reshape jq.
    if printf '%s' "$all" | grep -q 'api graphql' || [ "$path" = "graphql" ]; then
      qnum=""
      j=0; qargs=("$@")
      while [ $j -lt ${#qargs[@]} ]; do
        case "${qargs[$j]}" in -F) j=$((j+1)); case "${qargs[$j]}" in num=*) qnum="${qargs[$j]#num=}";; esac ;; esac
        j=$((j+1))
      done
      jq -c --argjson n "${qnum:-0}" '
        (.items[] | select(.content.number==$n)) as $it
        | { data: { repository: { issue: {
              title: $it.content.title,
              projectItems: { nodes: [ {
                id: $it.id,
                project: { number: 3 },
                fieldValues: { nodes: [
                  { __typename:"ProjectV2ItemFieldSingleSelectValue", name: $it.status, field:{name:"Status"} },
                  { __typename:"ProjectV2ItemFieldTextValue", text: ($it["host/Session"] // ""), field:{name:"Host/Session"} }
                ] }
              } ] }
        } } } }' "$S/resolve_item.json"
      exit 0
    fi

    case "$path" in
      search/issues)
        # The -f q="..." search; serve canned hit (search_hit.json) or empty.
        out="$(cat "$S/search_hit.json" 2>/dev/null || echo '{"items":[]}')"
        ;;
      */sub_issues)
        if [ "$method" = "POST" ]; then
          log "sub_issue_link epic=$path child_id=$post_id"
          out='{}'
        else
          out="$(cat "$S/sub_issues.json" 2>/dev/null || echo '[]')"
        fi
        ;;
      repos/*/issues/*)
        # Single issue object — serve from per-number fixture if present.
        num="${path##*/}"
        out="$(cat "$S/issue_$num.json" 2>/dev/null || cat "$S/issue.json")"
        ;;
      *)
        out='{}'
        ;;
    esac
    if [ -n "$jqf" ]; then printf '%s' "$out" | jq -r "$jqf"; else printf '%s' "$out"; fi
    exit 0
    ;;

  issue)
    sub="${2:-}"
    case "$sub" in
      create)
        log "issue_create $*"
        cat "$S/created_url.txt" 2>/dev/null || echo "https://github.com/Towheads/foundation/issues/777"
        ;;
      close)
        # issue close <num> -R repo
        log "issue_close $3"
        ;;
      edit)
        log "issue_edit $*"
        ;;
      *) echo "stub: unknown issue subcmd $sub" >&2; exit 3 ;;
    esac
    exit 0
    ;;

  project)
    sub="${2:-}"
    case "$sub" in
      view)       cat "$S/project_view.json" ;;
      field-list) cat "$S/field_list.json" ;;
      item-edit)
        # record the field-id + option/text the edit set
        fid=""; opt=""; txt=""; clear=0
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            --field-id) fid="$2"; shift 2 ;;
            --single-select-option-id) opt="$2"; shift 2 ;;
            --text) txt="$2"; shift 2 ;;
            --clear) clear=1; shift ;;
            *) shift ;;
          esac
        done
        log "item_edit field=$fid opt=$opt text=$txt clear=$clear"
        ;;
      item-add)
        log "item_add $*"
        ;;
      *) echo "stub: unknown project subcmd $sub" >&2; exit 3 ;;
    esac
    exit 0
    ;;

  *)
    echo "stub: unhandled gh call: $all" >&2
    exit 3
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- shared board structure fixtures (project view + field-list) --------------
cat > "$STATE/project_view.json" <<'EOF'
{"id":"PVT_TEST","number":4}
EOF
cat > "$STATE/field_list.json" <<'EOF'
{"fields":[
  {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_backlog","name":"Backlog"},
    {"id":"opt_ready","name":"Ready"},
    {"id":"opt_inprogress","name":"In Progress"},
    {"id":"opt_done","name":"Done"}]},
  {"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}
]}
EOF

# Helper: write the single-item resolve fixture (board_resolve_item shape) for an
# issue number, with a status + host/Session stamp.
write_resolve() {  # <num> <status> <stamp>
  cat > "$STATE/resolve_item.json" <<EOF
{"items":[{"id":"PVTI_item$1","content":{"number":$1,"title":"Item $1","type":"Issue"},"status":"$2","host/Session":"$3"}]}
EOF
}
# Default single issue object (open).
cat > "$STATE/issue.json" <<'EOF'
{"number":0,"state":"open","html_url":"https://github.com/Towheads/foundation/issues/0","id":9000}
EOF

board_args() { echo "--board 4"; }

# =============================================================================
# 2.5 ensure-issue
# =============================================================================
# (a) back-link probe HIT -> reuse, no create (ISSUE_EXISTS).
echo '{"items":[{"number":501}]}' > "$STATE/search_hit.json"
write_resolve 501 "Backlog" ""            # already on board -> no capture
: >"$LOG"
out="$(bash "$SCRIPT" ensure-issue --board 4 --title "T" --backlink "build-item:abc")"
[ "$(jq -r .outcome <<<"$out")" = "ISSUE_EXISTS" ] || fail "2.5a expected ISSUE_EXISTS (got $out)"
[ "$(jq -r .issue   <<<"$out")" = "501" ]          || fail "2.5a wrong issue (got $out)"
grep -q 'issue_create' "$LOG" && fail "2.5a created an issue despite a back-link hit (idempotency broken)"
echo "PASS: 2.5 ensure-issue reuses on a back-link hit (in:body probe) — no create"

# (b) NO hit -> create + land on board (ISSUE_CREATED), back-link embedded.
echo '{"items":[]}' > "$STATE/search_hit.json"
echo "https://github.com/Towheads/foundation/issues/777" > "$STATE/created_url.txt"
write_resolve 777 "Backlog" ""            # capture flow: resolves as already present
: >"$LOG"
out="$(bash "$SCRIPT" ensure-issue --board 4 --title "New work" --backlink "build-item:xyz" --label spike)"
[ "$(jq -r .outcome <<<"$out")" = "ISSUE_CREATED" ] || fail "2.5b expected ISSUE_CREATED (got $out)"
[ "$(jq -r .issue   <<<"$out")" = "777" ]           || fail "2.5b wrong issue (got $out)"
grep -q 'issue_create' "$LOG" || fail "2.5b did not create the issue"
grep -q 'build-item:xyz' "$LOG" || fail "2.5b back-link not embedded in created body"
echo "PASS: 2.5 ensure-issue creates + lands on board when no back-link exists (back-link embedded)"

# =============================================================================
# 2.6 ensure-epic
# =============================================================================
# Epic #100 already has child 11 linked; children 12,13 are new. issue lookups
# resolve each child's id; sub_issues lists existing children.
cat > "$STATE/issue.json" <<'EOF'
{"number":0,"state":"open","html_url":"x","id":1200}
EOF
cat > "$STATE/issue_100.json" <<'EOF'
{"number":100,"state":"open","id":100100}
EOF
echo '[{"number":11,"state":"open"}]' > "$STATE/sub_issues.json"
: >"$LOG"
out="$(bash "$SCRIPT" ensure-epic --board 4 --epic 100 --child 11,12,13)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_LINKED" ] || fail "2.6 expected EPIC_LINKED (got $out)"
[ "$(jq -c '.skipped' <<<"$out")" = "[11]" ]      || fail "2.6 #11 not skipped as already-linked (got $out)"
[ "$(jq -c '.linked'  <<<"$out")" = "[12,13]" ]   || fail "2.6 #12,#13 not linked (got $out)"
[ "$(grep -c 'sub_issue_link' "$LOG")" -eq 2 ]    || fail "2.6 expected exactly 2 link calls (got $(grep -c sub_issue_link "$LOG"))"
echo "PASS: 2.6 ensure-epic links unlinked children + SKIPS already-linked (idempotent)"

# (b) idempotent re-run: now ALL children are linked -> zero new links.
echo '[{"number":11,"state":"open"},{"number":12,"state":"open"},{"number":13,"state":"open"}]' > "$STATE/sub_issues.json"
: >"$LOG"
out="$(bash "$SCRIPT" ensure-epic --board 4 --epic 100 --child 11,12,13)"
[ "$(jq -c '.linked' <<<"$out")" = "[]" ]      || fail "2.6b re-run linked something (got $out)"
[ "$(grep -c 'sub_issue_link' "$LOG")" -eq 0 ] || fail "2.6b re-run issued a link call (not idempotent)"
echo "PASS: 2.6 ensure-epic re-run with all children linked is a no-op (idempotent)"

# =============================================================================
# 3a claim-item
# =============================================================================
# (a) contention: #200 already In Progress under a FOREIGN stamp -> CONTENDED + exit 1.
write_resolve 200 "In Progress" "otherhost:beef0000"
rc=0; out="$(bash "$SCRIPT" claim-item --board 4 --issue 200)" || rc=$?
[ "$rc" -ne 0 ] || fail "3a contention did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "CONTENDED" ] || fail "3a expected CONTENDED (got $out)"
[ "$(jq -r .owner   <<<"$out")" = "otherhost:beef0000" ] || fail "3a wrong owner (got $out)"
echo "PASS: 3a claim-item HALTS (CONTENDED) when a different live session owns it"

# (a-issues) contention on the ISSUES-ONLY backend — now the live path for boards
# 3/4/5/6 mid-cutover (#470). Board 4 is flipped backend=issues via a machine-level
# boards.conf; board_resolve_item then takes its ISSUES path (a `gh api
# repos/.../issues/<n>` REST read reshaped from `fnd:` labels), NOT the Projects-v2
# projectItems GraphQL stub. The 3a pre-check must read cur_status from the
# `fnd:status:in-progress` label and cur_stamp from the `fnd:host/session:` label and
# HALT (CONTENDED) under a foreign stamp. To PROVE the labels path is the one
# exercised (and the projectItems stub is NOT), point the Projects-v2 resolve fixture
# at #205 as an UNCLAIMED Ready item with no stamp: were the projects path wrongly
# taken here, cur_status would read "Ready" and the pre-check would proceed to claim
# rather than HALT — so a CONTENDED outcome can ONLY come from the issues reshape.
cat > "$STATE/issues_backend.conf" <<'EOF'
board.4.backend=issues
EOF
write_resolve 205 "Ready" ""     # projectItems stub: would NOT contend if wrongly taken
cat > "$STATE/issue_205.json" <<'EOF'
{"number":205,"state":"open","id":205205,"labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:otherhost:beef0000"}]}
EOF
rc=0
out="$(BOARDS_CONF_MACHINE="$STATE/issues_backend.conf" bash "$SCRIPT" claim-item --board 4 --issue 205)" || rc=$?
[ "$rc" -ne 0 ] || fail "3a issues-backend contention did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "CONTENDED" ] || fail "3a issues-backend expected CONTENDED (got $out)"
[ "$(jq -r .owner   <<<"$out")" = "otherhost:beef0000" ] || fail "3a issues-backend wrong owner (got $out)"
echo "PASS: 3a claim-item HALTS (CONTENDED) on the ISSUES-ONLY backend (fnd:status + fnd:host/session labels, not the projectItems stub)"

# (b) claim a Ready item + move the epic In Progress on first claim.
#     claim.sh resolves the ISSUE; then we resolve the EPIC. Both share the one
#     resolve_item.json, so point it at whichever is being resolved by sequencing:
#     claim.sh resolves #201 (Ready) — but it re-reads live each call. We give a
#     resolve that matches by number via the stub's single file; since both the
#     issue (#201, Ready) and epic (#300, Ready) must resolve, use a 2-item file.
cat > "$STATE/resolve_item.json" <<'EOF'
{"items":[
  {"id":"PVTI_item201","content":{"number":201,"title":"Item 201","type":"Issue"},"status":"Ready","host/Session":""},
  {"id":"PVTI_item300","content":{"number":300,"title":"Epic 300","type":"Issue"},"status":"Ready","host/Session":""}
]}
EOF
: >"$LOG"
out="$(bash "$SCRIPT" claim-item --board 4 --issue 201 --epic 300)"
[ "$(jq -r .outcome    <<<"$out")" = "CLAIMED" ] || fail "3b expected CLAIMED (got $out)"
[ "$(jq -r .epic_moved <<<"$out")" = "true" ]    || fail "3b epic not moved (got $out)"
# The epic move issues a Status=In Progress edit on the epic's item id.
grep -q 'item_edit field=PVTSSF_status opt=opt_inprogress' "$LOG" \
  || fail "3b epic In-Progress status edit not issued"
echo "PASS: 3a claim-item claims the item + moves the epic In Progress on first claim"

# (c) idempotent epic move: epic already In Progress -> epic_moved=false.
cat > "$STATE/resolve_item.json" <<'EOF'
{"items":[
  {"id":"PVTI_item202","content":{"number":202,"title":"Item 202","type":"Issue"},"status":"Ready","host/Session":""},
  {"id":"PVTI_item300","content":{"number":300,"title":"Epic 300","type":"Issue"},"status":"In Progress","host/Session":"testhost:sess1234"}
]}
EOF
out="$(bash "$SCRIPT" claim-item --board 4 --issue 202 --epic 300)"
[ "$(jq -r .epic_moved <<<"$out")" = "false" ] || fail "3c epic re-moved despite already In Progress (got $out)"
echo "PASS: 3a claim-item leaves an already-In-Progress epic untouched (idempotent)"

# =============================================================================
# 4d-epic close-epic
# =============================================================================
# (a) zero open children -> EPIC_CLOSED.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400}
EOF
echo '[{"number":41,"state":"closed"},{"number":42,"state":"closed"}]' > "$STATE/sub_issues.json"
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_CLOSED" ] || fail "4d-epic expected EPIC_CLOSED (got $out)"
grep -q 'issue_close 400' "$LOG" || fail "4d-epic did not close #400"
echo "PASS: 4d-epic closes the epic when open-children count hits 0 (data-driven)"

# (b) idempotent: epic ALREADY closed -> EPIC_ALREADY_CLOSED, no close call.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"closed","id":400400}
EOF
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_ALREADY_CLOSED" ] || fail "4d-epic re-run expected EPIC_ALREADY_CLOSED (got $out)"
grep -q 'issue_close' "$LOG" && fail "4d-epic re-run issued a close on an already-closed epic (not idempotent)"
echo "PASS: 4d-epic on an already-closed epic is a no-op (idempotent)"

# (c) still-open children -> EPIC_OPEN_CHILDREN, no close.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400}
EOF
echo '[{"number":41,"state":"open"},{"number":42,"state":"closed"}]' > "$STATE/sub_issues.json"
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_OPEN_CHILDREN" ] || fail "4d-epic expected EPIC_OPEN_CHILDREN (got $out)"
[ "$(jq -r .open <<<"$out")" = "1" ] || fail "4d-epic wrong open count (got $out)"
grep -q 'issue_close' "$LOG" && fail "4d-epic closed despite open children"
echo "PASS: 4d-epic does NOT close while a child is still open"

# temperloop#458 — body-acceptance guard (children drained; epic body still carries
# unchecked acceptance/verification prose that was never split into a sub-issue).
echo '[{"number":41,"state":"closed"},{"number":42,"state":"closed"}]' > "$STATE/sub_issues.json"

# (d) zero open children BUT an unchecked acceptance box in the body -> refuse close.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400,"body":"## Acceptance\n\n- [ ] induced crash converges to a board item\n- [x] handled error converges\n"}
EOF
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_ACCEPTANCE_OPEN" ] || fail "4d-epic expected EPIC_ACCEPTANCE_OPEN (got $out)"
[ "$(jq -r .acceptance_open <<<"$out")" = "1" ] || fail "4d-epic wrong acceptance_open count (got $out)"
grep -q 'issue_close' "$LOG" && fail "4d-epic closed despite an open body-acceptance box"
echo "PASS: 4d-epic REFUSES to close while an unchecked body acceptance box remains"

# (e) same body, but the explicit override closes anyway (acceptance_override flagged).
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400 --allow-open-acceptance)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_CLOSED" ] || fail "4d-epic override expected EPIC_CLOSED (got $out)"
[ "$(jq -r '.acceptance_override' <<<"$out")" = "true" ] || fail "4d-epic override did not flag acceptance_override (got $out)"
grep -q 'issue_close 400' "$LOG" || fail "4d-epic override did not close #400"
echo "PASS: 4d-epic --allow-open-acceptance overrides the guard and closes (flagged)"

# (f) no-regression: heading-scoped + checked boxes -> close normally.
#   Only sections whose heading matches /accept|verif/i are scanned; an unchecked
#   box under a non-acceptance heading, and a CHECKED acceptance box, are ignored.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400,"body":"## Tasks\n\n- [ ] some non-acceptance note\n\n## Acceptance\n\n- [x] all e2e legs green\n"}
EOF
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_CLOSED" ] || fail "4d-epic no-regression expected EPIC_CLOSED (got $out)"
grep -q 'issue_close 400' "$LOG" || fail "4d-epic no-regression did not close #400"
echo "PASS: 4d-epic closes normally when acceptance boxes are checked (heading-scoped, no false positive)"

# (g) child-reference checkboxes under Acceptance are NOT body acceptance -> close.
#   `- [ ] #N` / `- [ ] owner/repo#N` are tracked by the sub-issue state count, so
#   they must not block the close as if they were freestanding acceptance prose.
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400,"body":"## Acceptance\n\n- [ ] #358\n- [ ] Towheads/foundation#709\n"}
EOF
: >"$LOG"
out="$(bash "$SCRIPT" close-epic --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_CLOSED" ] || fail "4d-epic child-ref case expected EPIC_CLOSED (got $out)"
grep -q 'issue_close 400' "$LOG" || fail "4d-epic child-ref case did not close #400"
echo "PASS: 4d-epic ignores bare #N / owner/repo#N child-ref checkboxes under Acceptance"

# restore the all-closed children fixture for downstream tests (retro/park reuse it)
cat > "$STATE/issue_400.json" <<'EOF'
{"number":400,"state":"open","id":400400}
EOF

# =============================================================================
# 4d-retro file-retro
# =============================================================================
# (a) just-closed + no existing marker -> RETRO_FILED (spike, Backlog).
echo '{"items":[]}' > "$STATE/search_hit.json"
echo "https://github.com/Towheads/foundation/issues/888" > "$STATE/created_url.txt"
write_resolve 888 "Backlog" ""
: >"$LOG"
out="$(bash "$SCRIPT" file-retro --board 4 --epic 400 --just-closed)"
[ "$(jq -r .outcome <<<"$out")" = "RETRO_FILED" ] || fail "4d-retro expected RETRO_FILED (got $out)"
[ "$(jq -r .retro <<<"$out")" = "888" ] || fail "4d-retro wrong retro number (got $out)"
grep -q 'issue_create' "$LOG" || fail "4d-retro did not create the retro"
grep -q -- '--label spike' "$LOG" || fail "4d-retro retro not spike-labelled"
grep -q 'Retro-for-epic: #400' "$LOG" || fail "4d-retro body-marker not embedded"
echo "PASS: 4d-retro files exactly one spike retro into Backlog on a fresh close (marker embedded)"

# (b) idempotent: marker ALREADY present -> RETRO_EXISTS, no second create.
echo '{"items":[{"number":888}]}' > "$STATE/search_hit.json"
: >"$LOG"
out="$(bash "$SCRIPT" file-retro --board 4 --epic 400 --just-closed)"
[ "$(jq -r .outcome <<<"$out")" = "RETRO_EXISTS" ] || fail "4d-retro re-run expected RETRO_EXISTS (got $out)"
[ "$(jq -r .retro <<<"$out")" = "888" ] || fail "4d-retro re-run wrong retro (got $out)"
grep -q 'issue_create' "$LOG" && fail "4d-retro re-run filed a SECOND retro (not idempotent)"
echo "PASS: 4d-retro on an epic whose retro marker exists is a no-op (idempotent)"

# (c) not just-closed -> RETRO_SKIPPED.
out="$(bash "$SCRIPT" file-retro --board 4 --epic 400)"
[ "$(jq -r .outcome <<<"$out")" = "RETRO_SKIPPED" ] || fail "4d-retro without --just-closed expected RETRO_SKIPPED (got $out)"
echo "PASS: 4d-retro is an explicit no-op without --just-closed"

# =============================================================================
# Step-5 park-epic
# =============================================================================
# (a) our own In-Progress epic -> EPIC_PARKED (Ready + stamp cleared).
cat > "$STATE/issue_300.json" <<'EOF'
{"number":300,"state":"open","id":300300}
EOF
write_resolve 300 "In Progress" "testhost:sess1234"
: >"$LOG"
out="$(bash "$SCRIPT" park-epic --board 4 --epic 300)"
[ "$(jq -r .outcome <<<"$out")" = "EPIC_PARKED" ] || fail "Step-5 expected EPIC_PARKED (got $out)"
grep -q 'item_edit field=PVTSSF_status opt=opt_ready' "$LOG" || fail "Step-5 did not move epic to Ready"
grep -q 'item_edit field=PVTF_hostsession .*clear=1' "$LOG" || fail "Step-5 did not clear the stamp"
echo "PASS: Step-5 park-epic moves our own In-Progress epic -> Ready + clears stamp"

# (b) foreign stamp -> PARK_FOREIGN, untouched.
write_resolve 300 "In Progress" "otherhost:cafe0000"
: >"$LOG"
out="$(bash "$SCRIPT" park-epic --board 4 --epic 300)"
[ "$(jq -r .outcome <<<"$out")" = "PARK_FOREIGN" ] || fail "Step-5 expected PARK_FOREIGN (got $out)"
grep -q 'item_edit' "$LOG" && fail "Step-5 touched an epic owned by a different session"
echo "PASS: Step-5 park-epic leaves a different live session's epic untouched (PARK_FOREIGN)"

# (c) closed epic -> PARK_SKIPPED.
cat > "$STATE/issue_300.json" <<'EOF'
{"number":300,"state":"closed","id":300300}
EOF
out="$(bash "$SCRIPT" park-epic --board 4 --epic 300)"
[ "$(jq -r .outcome <<<"$out")" = "PARK_SKIPPED" ] || fail "Step-5 closed-epic expected PARK_SKIPPED (got $out)"
echo "PASS: Step-5 park-epic skips a closed epic (nothing to park)"

# =============================================================================
# error: closed ERROR outcome + non-zero exit on bad input
# =============================================================================
rc=0; out="$(bash "$SCRIPT" close-epic --board 9 --epic 1 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "unknown board not structured ERROR (got $out)"
rc=0; out="$(bash "$SCRIPT" close-epic --board 4 --epic abc 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "non-numeric --epic not structured ERROR (got $out)"
rc=0; out="$(bash "$SCRIPT" bogus-cmd 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "unknown subcommand not structured ERROR (got $out)"
echo "PASS: bad input emits structured ERROR + non-zero exit (closed outcome set)"

echo
echo "PASS: all board-mirror.sh entrypoint assertions passed"
