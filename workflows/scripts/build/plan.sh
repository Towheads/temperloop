#!/usr/bin/env bash
#
# build plan-note mechanics — the deterministic-spine script that owns the
# Step-1 plan parse/validate + dependency-level toposort and the in-band
# sentinel writeback of /build (epic #253, spike #245). These are pure
# functions of the plan note's text with closed outcome sets, so they move from
# prose in build.md to code here; the judgment-shaped halves (what to DO
# with a validation failure, which item to spawn next) stay orchestrator-driven.
#
#   plan.sh validate  <planFile>                 # schema validation (plan-schema.md § Validation rules)
#   plan.sh toposort  <planFile>                 # dependency levels from depends-on ∪ after
#   plan.sh writeback <planFile> --slug <slug> --sentinel <state> \
#         [--pr N] [--pushed-sha SHA] [--speculative] [--run-status <text>]
#
# `validate` enforces the 11 plan-schema rules (status==approved, slug+acceptance
# present, unique kebab slugs ≤40, branch <type>/<slug>, depends-on/after refs
# exist, the depends-on∪after union acyclic, no leftover acceptance placeholder,
# gh_issue a positive int, gh_issue/split_from mutual exclusion, the rule-11
# external-gate gate_check requirement). `toposort` partitions items into
# dependency levels — level 0 = items with neither depends-on nor after — over
# the UNION of both edge sets, and emits `{"levels":[["a","b"],["c"]]}` on stdout.
#
# `writeback` flips an item's checkbox sentinel ([ ]→[~]→[m]→[x], plus [v]/[-])
# and stamps sub-lines (pr:, pushed_sha:, speculative:, Run-status:) on the plan
# note. It is the SOLE sentinel-writeback path: ALL vault writes route through a
# single `_plan_vault_write` indirection (mirrors board.sh's `_board_gh`),
# overridable in tests.
#
# The write is TWO-TIER, resolved per call (#342):
#   1. If an Obsidian Local REST API config (the plugin's data.json) is found —
#      via PLAN_API_KEY_FILE / KNOWLEDGE_STORE_ROOT-derived, or the vault root
#      RESOLVED from the plan note's own absolute path — the patched note PUTs
#      to that REST API (the same API the board adapter and session-start-drain
#      hook use). A configured-but-unreachable REST API FAILS LOUD (WRITE_FAILED
#      + non-zero) — never silent success — because a sentinel write IS the
#      resume-safety substrate and a silent loss loses resume state.
#   2. If NO REST config is found (e.g. a temperloop kernel checkout whose vault
#      has no Local REST API plugin), the write FAILS SOFT to a direct
#      filesystem write of the plan note's on-disk path — the sentinel is still
#      persisted durably (resume-safety intact), just via the filesystem instead
#      of REST. Only when there is neither a REST config NOR a writable on-disk
#      plan path does it emit WRITE_SKIPPED — a soft, non-fatal outcome the
#      orchestrator can handle (vs. the hard WRITE_FAILED of a broken endpoint).
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome
# (exception: `toposort` prints the `{"levels":…}` object directly):
#   validate  → {"outcome":"VALID"} |
#               {"outcome":"INVALID","errors":[…]} + non-zero exit
#   toposort  → {"levels":[[…],…],"order":[…]} |
#               {"outcome":"CYCLE","cycle":[…]} + non-zero exit
#   writeback → {"outcome":"WRITTEN","slug":…,"sentinel":…} |
#               {"outcome":"WRITE_SKIPPED","slug":…,"reason":…} (soft; zero exit) |
#               {"outcome":"WRITE_FAILED","slug":…,"error":…} + non-zero exit
#   error     → {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout. Helpers run inside command substitutions,
# where a die()'s ERROR line would be captured by the caller instead of reaching
# the orchestrator — emitting via fd 3 keeps the structured error on the real
# stdout regardless of call context (same seam as pr.sh / ci-poll.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: plan.sh validate <planFile> | toposort <planFile> | writeback <planFile> --slug <slug> --sentinel <[ ]|[~]|[m]|[x]|[v]|[-]> [--pr N] [--pushed-sha SHA] [--speculative] [--run-status <text>]"
}

# --- the ONE test-injection seam ---------------------------------------------
# Every sentinel write goes through here. Production PUTs the patched note to the
# Obsidian Local REST API; tests override this after sourcing
# (e.g. `_plan_vault_write() { fake_write "$@"; }`) so NO live REST call happens
# in the suite. Mirrors board.sh's `_board_gh`.
#
#   _plan_vault_write <vaultRelPath> <contentFile>
#
# Return-code contract (consumed by cmd_writeback):
#   0  → written (via REST when configured, else the filesystem fallback)
#   1  → REST was CONFIGURED but the write FAILED (unreachable / HTTP error) —
#        fail loud (WRITE_FAILED); a configured endpoint going silent loses
#        resume state, so this stays a hard, non-zero failure.
#   3  → no REST config AND no writable on-disk plan path — WRITE_SKIPPED, a
#        SOFT outcome (nothing was persisted, but nothing was broken either).
# Config default resolution routes through the knowledge_store seam's obsidian
# backend (foundation #777, Epic A #762 "kernel split") rather than a literal:
# KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE / _API_BASE already default to today's
# vault path/URL in that ONE file (knowledge_store_obsidian.sh), so plan.sh no
# longer repeats the literal here. PLAN_API_BASE / PLAN_API_KEY_FILE remain the
# names tests/callers override (unchanged surface) — they now fall back to the
# seam's own knobs instead of a hardcoded default.
PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
if [ -f "$PLAN_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=workflows/scripts/lib/knowledge_store.sh
  . "$PLAN_LIB_DIR/knowledge_store.sh"
fi
if [ -f "$PLAN_LIB_DIR/knowledge_store_obsidian.sh" ]; then
  # shellcheck source=workflows/scripts/lib/knowledge_store_obsidian.sh
  . "$PLAN_LIB_DIR/knowledge_store_obsidian.sh"
fi
PLAN_API_BASE="${PLAN_API_BASE:-${KNOWLEDGE_STORE_OBSIDIAN_API_BASE:-https://127.0.0.1:27124}}"
PLAN_API_KEY_FILE="${PLAN_API_KEY_FILE:-${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:-}}"

# Resolve the Obsidian Local REST API key file for THIS writeback, printing the
# first existing candidate on stdout (exit 0), or exit 1 when none exists (=>
# no REST config, the caller falls soft to a filesystem write). Resolution
# order, most-specific first (#342):
#   1. PLAN_API_KEY_FILE — the caller/test override, itself defaulted from the
#      knowledge_store seam's KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE knob (which
#      derives from KNOWLEDGE_STORE_ROOT — the "actual knowledge-store root").
#   2. The vault root RESOLVED from the plan note's own absolute on-disk path:
#      the parent of its `/Plans/` segment. This is what makes writeback work in
#      a checkout whose vault differs from the KNOWLEDGE_STORE_ROOT default
#      (e.g. a temperloop kernel checkout whose vault lives under a non-default
#      knowledge-store root, writing that vault's own /Plans/…): the plan
#      file's location is the ground truth for which vault it belongs to.
# A resolved candidate must actually EXIST on disk to be used — a nonexistent
# path is treated as "no REST config here", not a hard error.
_plan_resolve_api_key_file() {
  local on_disk="${1:-}" vault_root cand
  if [ -n "$PLAN_API_KEY_FILE" ] && [ -f "$PLAN_API_KEY_FILE" ]; then
    printf '%s\n' "$PLAN_API_KEY_FILE"
    return 0
  fi
  case "$on_disk" in
    /*/Plans/*)
      vault_root="${on_disk%%/Plans/*}"
      cand="$vault_root/.obsidian/plugins/obsidian-local-rest-api/data.json"
      if [ -f "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
      ;;
  esac
  return 1
}

# _plan_vault_write <vaultRelPath> <contentFile> [<onDiskPath>]
_plan_vault_write() {
  local vault_path="$1" content_file="$2" on_disk="${3:-}" \
        api_key http_code encoded_path key_file
  if key_file="$(_plan_resolve_api_key_file "$on_disk")"; then
    # --- Tier 1: a REST config exists → PUT to the Obsidian Local REST API ----
    api_key="$(jq -r '.apiKey // empty' "$key_file" 2>/dev/null)"
    [ -n "$api_key" ] || { echo "plan.sh: could not read apiKey from $key_file" >&2; return 1; }
    # URL-encode each path SEGMENT (preserving the '/' separators) before the PUT.
    # Plan filenames carry spaces per the canonical 'Plans/<date> <project> -
    # <title>.md' convention; interpolated raw, curl rejects the URL (exit 3,
    # http_code 000) and writeback breaks for EVERY real plan (#364). jq @uri
    # percent-encodes per segment so 'Plans/a b.md' → 'Plans/a%20b.md'.
    encoded_path="$(printf '%s' "$vault_path" | jq -sRr 'split("/") | map(@uri) | join("/")')" \
      || { echo "plan.sh: failed to URL-encode vault path '$vault_path'" >&2; return 1; }
    # Whole-file PUT (idempotent); no PATCH, so the REST-API 4.0 targetScope rule
    # does not apply (cf. session-start-drain.sh, foundation #6).
    http_code="$(curl -s -k -o /dev/null -w '%{http_code}' \
      -X PUT "$PLAN_API_BASE/vault/$encoded_path" \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: text/markdown" \
      --data-binary "@$content_file" 2>/dev/null)" || {
        echo "plan.sh: REST API unreachable at $PLAN_API_BASE (curl failed)" >&2
        return 1
      }
    case "$http_code" in
      200|204) return 0 ;;
      000|"") echo "plan.sh: REST API unreachable at $PLAN_API_BASE (no response)" >&2; return 1 ;;
      *) echo "plan.sh: REST API write to $vault_path failed (HTTP $http_code)" >&2; return 1 ;;
    esac
  fi

  # --- Tier 2: no REST config → fail SOFT to a direct filesystem write --------
  # The sentinel is still persisted durably (resume-safety intact), just to the
  # plan note's on-disk path instead of via REST. cmd_writeback verified the
  # path exists before calling us, so this is normally a straight overwrite.
  if [ -n "$on_disk" ] && cat "$content_file" > "$on_disk" 2>/dev/null; then
    echo "plan.sh: no Obsidian REST config found; wrote sentinel directly to $on_disk (filesystem fallback)" >&2
    return 0
  fi
  echo "plan.sh: no REST config and no writable on-disk plan path — sentinel NOT persisted (WRITE_SKIPPED)" >&2
  return 3
}

# --- plan-note parsing -------------------------------------------------------
# A plan note is markdown: YAML frontmatter (--- … ---) then a `## Items`
# section of `- [ ] **title** `slug: x` …` blocks with indented sub-line fields.
# We parse in awk: emit one TSV record per item with its fields, and frontmatter
# `status:` separately. Robust to field order and to extra whitespace.

# Read the frontmatter `status:` value (first `status:` between the leading --- markers).
fm_status() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); gsub(/[[:space:]]+$/,"");
      print; exit
    }
  ' "$1"
}

# Emit, for each item, a line: SLUG<TAB>FIELD=VALUE pairs joined by US (0x1f).
# Recognized fields: slug, branch, depends-on, after, gh_issue, split_from,
# gate_check, acceptance (=1 if a non-empty acceptance block exists),
# acceptance_placeholder (=1 if the placeholder line is present), notes,
# sentinel (the current checkbox char), title.
# This is the single parse used by validate/toposort/writeback.
parse_items() {
  awk '
    function flush() {
      if (have_item) {
        rec = slug
        rec = rec SEP "sentinel=" sentinel
        rec = rec SEP "title=" title
        rec = rec SEP "branch=" branch
        rec = rec SEP "dependson=" dependson
        rec = rec SEP "after=" after
        rec = rec SEP "gh_issue=" gh_issue
        rec = rec SEP "split_from=" split_from
        rec = rec SEP "gate_check=" gate_check
        rec = rec SEP "notes=" notes
        rec = rec SEP "acceptance=" (acc_count>0 ? "1" : "0")
        rec = rec SEP "acc_placeholder=" acc_placeholder
        print rec
      }
      have_item=0; slug=""; sentinel=""; title=""; branch=""; dependson="";
      after=""; gh_issue=""; split_from=""; gate_check=""; notes="";
      acc_count=0; acc_placeholder=0; in_acc=0
    }
    BEGIN { SEP=sprintf("%c",31); in_items=0 }
    /^##[[:space:]]+Items[[:space:]]*$/ { in_items=1; next }
    in_items && /^##[[:space:]]/ { flush(); in_items=0; next }
    !in_items { next }

    # Item header: - [x] **title** `slug: foo` — scope
    /^[[:space:]]*-[[:space:]]*\[.\]/ {
      flush()
      have_item=1
      line=$0
      # sentinel char between the brackets
      s=line; sub(/^[^[]*\[/,"",s); sentinel=substr(s,1,1)
      # title between ** **
      t=line
      if (match(t, /\*\*[^*]+\*\*/)) {
        title=substr(t, RSTART+2, RLENGTH-4)
      }
      # slug inside `slug: x`
      if (match(line, /`slug:[[:space:]]*[a-zA-Z0-9_-]+`/)) {
        sl=substr(line, RSTART, RLENGTH)
        gsub(/`/,"",sl); sub(/slug:[[:space:]]*/,"",sl); gsub(/[[:space:]]/,"",sl)
        slug=sl
      }
      in_acc=0
      next
    }

    # Sub-line fields (indented). We are inside an item block.
    have_item {
      l=$0
      # acceptance block: `- acceptance:` opens it; subsequent deeper bullets are entries.
      if (l ~ /^[[:space:]]*-[[:space:]]*acceptance:[[:space:]]*$/) { in_acc=1; next }
      if (in_acc) {
        # placeholder line is fatal at execution
        if (l ~ /no acceptance criteria derivable from source/) { acc_placeholder=1 }
        # a deeper bullet that is not itself a recognized field key counts as an entry
        if (l ~ /^[[:space:]]+-[[:space:]]+/) { acc_count++; next }
        # a same-level field key ends the acceptance block (fall through to field parse)
        if (l ~ /^[[:space:]]*-[[:space:]]*[a-zA-Z_-]+:/) { in_acc=0 }
        else { next }
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*branch:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*branch:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); branch=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*depends-on:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*depends-on:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); dependson=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*after:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*after:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); after=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*gh_issue:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*gh_issue:[[:space:]]*/,"",v); gsub(/#/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gh_issue=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*split_from:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*split_from:[[:space:]]*/,"",v); gsub(/[[:space:]]+#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); split_from=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*gate_check:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*gate_check:[[:space:]]*/,"",v); gate_check=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*notes:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*notes:[[:space:]]*/,"",v); notes=v; next
      }
    }
    END { flush() }
  ' "$1"
}

# Extract a single field from a parsed record line.
rec_field() {
  local rec="$1" key="$2"
  awk -v k="$key" 'BEGIN{SEP=sprintf("%c",31)}{
    n=split($0,a,SEP)
    for(i=2;i<=n;i++){ p=index(a[i],"="); if(substr(a[i],1,p-1)==k){print substr(a[i],p+1); exit}}
  }' <<<"$rec"
}
rec_slug() { awk 'BEGIN{FS=sprintf("%c",31)}{print $1; exit}' <<<"$1"; }

# Split a comma/space-separated slug list into space-separated tokens.
split_list() { printf '%s' "$1" | tr ',' ' ' | xargs 2>/dev/null || true; }

# --- validate ----------------------------------------------------------------
cmd_validate() {
  local file="$1" records status errors=() slug rec
  [ -f "$file" ] || die "plan file '$file' does not exist"
  status="$(fm_status "$file")"
  records="$(parse_items "$file")"
  [ -n "$records" ] || die "no items found under '## Items' in '$file'"

  # Rule 1: status must be approved (not draft / missing).
  if [ "$status" != "approved" ]; then
    errors+=("rule 1: frontmatter status is '${status:-<missing>}', must be 'approved'")
  fi

  # Build slug set first (for ref-existence + uniqueness). Bash 3.2 — no
  # associative arrays; track membership in comma-fenced strings.
  local all_slugs=() seen_slugs="," seen_dupes=","
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slug="$(rec_slug "$rec")"
    if [ -z "$slug" ]; then
      errors+=("rule 3: an item has no slug: (title='$(rec_field "$rec" title)')")
      continue
    fi
    all_slugs+=("$slug")
  done <<<"$records"

  # Rule 3 (uniqueness) + slug charset/length.
  for slug in "${all_slugs[@]}"; do
    if [[ "$seen_slugs" == *",$slug,"* ]] && [[ "$seen_dupes" != *",$slug,"* ]]; then
      errors+=("rule 3: duplicate slug '$slug'")
      seen_dupes="$seen_dupes$slug,"
    fi
    seen_slugs="$seen_slugs$slug,"
    if ! [[ "$slug" =~ ^[a-z0-9-]+$ ]]; then
      errors+=("rule 3: slug '$slug' must match [a-z0-9-]+")
    fi
    if [ "${#slug}" -gt 40 ]; then
      errors+=("rule 3: slug '$slug' exceeds 40 chars")
    fi
  done

  # Per-item field rules.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slug="$(rec_slug "$rec")"
    [ -n "$slug" ] || continue
    local branch acc acc_ph gh_issue split_from gate_check notes dep aft tok
    branch="$(rec_field "$rec" branch)"
    acc="$(rec_field "$rec" acceptance)"
    acc_ph="$(rec_field "$rec" acc_placeholder)"
    gh_issue="$(rec_field "$rec" gh_issue)"
    split_from="$(rec_field "$rec" split_from)"
    gate_check="$(rec_field "$rec" gate_check)"
    notes="$(rec_field "$rec" notes)"
    dep="$(rec_field "$rec" dependson)"
    aft="$(rec_field "$rec" after)"

    # Rule 2: acceptance block present.
    [ "$acc" = "1" ] || errors+=("rule 2: item '$slug' has no acceptance: block")
    # Rule 9: no leftover acceptance placeholder.
    [ "$acc_ph" != "1" ] || errors+=("rule 9: item '$slug' still has the acceptance placeholder line")
    # Rule 4: branch matches <type>/<slug-ish>.
    if [ -n "$branch" ]; then
      [[ "$branch" =~ ^(feat|fix|chore|refactor|docs|test)/[a-z0-9-]+$ ]] \
        || errors+=("rule 4: item '$slug' branch '$branch' must match <type>/<slug> (type ∈ feat|fix|chore|refactor|docs|test)")
    fi
    # Rule 7: gh_issue (when present) a positive int.
    if [ -n "$gh_issue" ]; then
      { [[ "$gh_issue" =~ ^[0-9]+$ ]] && [ "$gh_issue" -gt 0 ]; } \
        || errors+=("rule 7: item '$slug' gh_issue '$gh_issue' must be a positive integer")
    fi
    # Rule 10: gh_issue/split_from mutual exclusion; split_from must be #<posint>.
    if [ -n "$split_from" ]; then
      if [ -n "$gh_issue" ]; then
        errors+=("rule 10: item '$slug' carries both gh_issue and split_from (mutually exclusive)")
      fi
      [[ "$split_from" =~ ^#[0-9]+$ ]] && [ "${split_from#\#}" -gt 0 ] 2>/dev/null \
        || errors+=("rule 10: item '$slug' split_from '$split_from' must be a #<positive-integer> ref")
    fi
    # Rule 11: a prose external/cross-plan gate in notes: needs a gate_check:.
    if [ -n "$notes" ] && [[ "$notes" =~ (do[[:space:]]not[[:space:]]start|don\'?t[[:space:]]start|until[[:space:]]+#[0-9]+|lands[[:space:]]*\(?#[0-9]+) ]]; then
      [ -n "$gate_check" ] || errors+=("rule 11: item '$slug' declares a prose external gate in notes: but carries no gate_check: predicate")
    fi
    # Rule 5/8: depends-on + after refs must exist in this plan.
    for tok in $(split_list "$dep"); do
      [[ ",$(IFS=,; echo "${all_slugs[*]}")," == *",$tok,"* ]] \
        || errors+=("rule 5: item '$slug' depends-on '$tok' which is not a slug in this plan")
    done
    for tok in $(split_list "$aft"); do
      [[ ",$(IFS=,; echo "${all_slugs[*]}")," == *",$tok,"* ]] \
        || errors+=("rule 8: item '$slug' after '$tok' which is not a slug in this plan")
    done
  done <<<"$records"

  # Rule 8 (acyclic): the union depends-on ∪ after must be a DAG. Reuse toposort.
  if ! topo_out="$(compute_levels "$records" 2>/dev/null)"; then
    local cyc
    cyc="$(jq -r '.cycle // [] | join(" -> ")' <<<"$topo_out" 2>/dev/null || true)"
    errors+=("rule 8: dependency cycle in depends-on ∪ after${cyc:+ ($cyc)}")
  fi

  if [ "${#errors[@]}" -eq 0 ]; then
    jq -cn '{outcome:"VALID"}'
  else
    printf '%s\n' "${errors[@]}" | jq -R . | jq -cs '{outcome:"INVALID", errors:.}'
    exit 1
  fi
}

# --- toposort ----------------------------------------------------------------
# Kahn's algorithm over the union of depends-on + after edges. Level 0 = items
# with in-degree 0 (no depends-on and no after). Emits the {"levels":…} object
# on success; on a cycle, prints {"outcome":"CYCLE","cycle":[…]} and exits 1.
# `compute_levels` is the shared core (also used by validate's acyclic check):
# it prints the levels JSON on stdout and returns non-zero on a cycle.
compute_levels() {
  local records="$1"
  printf '%s\n' "$records" | awk '
    BEGIN { SEP=sprintf("%c",31); FS=SEP }
    function field(rec, key,    n,a,i,p) {
      n=split(rec,a,SEP)
      for(i=2;i<=n;i++){ p=index(a[i],"="); if(substr(a[i],1,p-1)==key) return substr(a[i],p+1) }
      return ""
    }
    function addedge(from,to) {  # from must precede to
      if (!((from SUBSEP to) in seen_edge)) {
        seen_edge[from SUBSEP to]=1
        adj[from]=adj[from] (adj[from]==""?"":SUBSEP) to
        indeg[to]++
      }
    }
    {
      rec=$0
      slug=$1
      nodes[slug]=1
      order[++ncount]=slug
      if (indeg[slug]=="") indeg[slug]=0
      # collect edges; parse deferred until all nodes known
      deps[slug]=field(rec,"dependson")
      afts[slug]=field(rec,"after")
    }
    END {
      # build edges (predecessor -> slug)
      for (s in nodes) {
        split_list(deps[s], s)
        split_list(afts[s], s)
      }
      # Kahn by levels
      level=0; remaining=ncount
      while (remaining>0) {
        cnt=0
        # collect current zero-indegree (preserve authoring order)
        for (i=1;i<=ncount;i++){ s=order[i]; if(s in nodes && indeg[s]==0 && !(s in done)) cur[++cnt]=s }
        if (cnt==0) break   # cycle
        out=""
        for (i=1;i<=cnt;i++){ s=cur[i]; out=out (out==""?"":",") "\"" s "\"" }
        levels[level]="[" out "]"
        for (i=1;i<=cnt;i++){
          s=cur[i]; done[s]=1; remaining--
          n=split(adj[s],succ,SUBSEP)
          for(j=1;j<=n;j++){ if(succ[j]!="") indeg[succ[j]]-- }
        }
        delete cur
        level++
      }
      if (remaining>0) {
        # cycle: report the still-stuck nodes
        c=""
        for (i=1;i<=ncount;i++){ s=order[i]; if(!(s in done)){ c=c (c==""?"":",") "\"" s "\"" } }
        print "{\"outcome\":\"CYCLE\",\"cycle\":[" c "]}"
        exit 3
      }
      lv=""
      for (i=0;i<level;i++){ lv=lv (lv==""?"":",") levels[i] }
      ord=""
      for (i=1;i<=ncount;i++){ ord=ord (ord==""?"":",") "\"" order[i] "\"" }
      print "{\"levels\":[" lv "],\"order\":[" ord "]}"
    }
    function split_list(raw, to,    tmp,n,arr,i,t) {
      tmp=raw; gsub(/,/," ",tmp)
      n=split(tmp,arr," ")
      for(i=1;i<=n;i++){ t=arr[i]; if(t!="" && (t in nodes)) addedge(t,to) }
    }
  '
  local rc=$?
  [ "$rc" -eq 3 ] && return 1
  return "$rc"
}

cmd_toposort() {
  local file="$1" records out
  [ -f "$file" ] || die "plan file '$file' does not exist"
  records="$(parse_items "$file")"
  [ -n "$records" ] || die "no items found under '## Items' in '$file'"
  if out="$(compute_levels "$records")"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out"
    exit 1
  fi
}

# --- writeback ---------------------------------------------------------------
# Flip the named item's checkbox sentinel and stamp sub-lines, then PUT the
# patched note via the _plan_vault_write seam. A vault path is derived from the
# file path's tail under the vault root (Plans/<name>.md); the orchestrator
# always passes a path under the configured vault root, so the REST
# vault-relative path is the segment after the vault root.
cmd_writeback() {
  local file="" slug="" sentinel="" pr="" pushed_sha="" speculative="" run_status="" has_run_status=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)        [ $# -ge 2 ] || usage; slug="$2"; shift ;;
      --sentinel)    [ $# -ge 2 ] || usage; sentinel="$2"; shift ;;
      --pr)          [ $# -ge 2 ] || usage; pr="$2"; shift ;;
      --pushed-sha)  [ $# -ge 2 ] || usage; pushed_sha="$2"; shift ;;
      --speculative) speculative=1 ;;
      --run-status)  [ $# -ge 2 ] || usage; run_status="$2"; has_run_status=1; shift ;;
      --*)           usage ;;
      *)             if [ -z "$file" ]; then file="$1"; else usage; fi ;;
    esac
    shift
  done
  [ -n "$file" ]     || die "writeback requires <planFile>"
  [ -n "$slug" ]     || die "writeback requires --slug"
  [ -n "$sentinel" ] || die "writeback requires --sentinel"
  [ -f "$file" ]     || die "plan file '$file' does not exist"
  case "$sentinel" in
    ' '|~|m|x|v|-) sentinel="[$sentinel]" ;;        # bare char form
    '[ ]'|'[~]'|'[m]'|'[x]'|'[v]'|'[-]') : ;;       # bracketed form
    *) die "invalid sentinel '$sentinel' (one of: [ ] [~] [m] [x] [v] [-])" ;;
  esac

  # Confirm the slug exists.
  local records
  records="$(parse_items "$file")"
  grep -q "^${slug}$(printf '\037')" <<<"$records" \
    || die "slug '$slug' not found in '$file'"

  # Patch in a tmp copy: flip the sentinel on the slug's item header line, then
  # stamp/replace sub-lines within that item block.
  local tmp
  tmp="$(mktemp)"
  PLAN_SLUG="$slug" PLAN_SENTINEL="$sentinel" PLAN_PR="$pr" \
  PLAN_PUSHED_SHA="$pushed_sha" PLAN_SPECULATIVE="$speculative" \
  PLAN_RUN_STATUS="$run_status" PLAN_HAS_RUN_STATUS="$has_run_status" \
  awk '
    BEGIN {
      slug=ENVIRON["PLAN_SLUG"]; sent=ENVIRON["PLAN_SENTINEL"]
      pr=ENVIRON["PLAN_PR"]; sha=ENVIRON["PLAN_PUSHED_SHA"]
      spec=ENVIRON["PLAN_SPECULATIVE"]; rs=ENVIRON["PLAN_RUN_STATUS"]
      has_rs=ENVIRON["PLAN_HAS_RUN_STATUS"]
      in_item=0; pr_done=0; sha_done=0; spec_done=0; rs_done=0
    }
    # leaving the target item block: flush any not-yet-present sub-lines.
    function flush_stamps() {
      if (pr!="" && !pr_done)   print "  - pr: " pr
      if (sha!="" && !sha_done) print "  - pushed_sha: " sha
      if (spec=="1" && !spec_done) print "  - speculative: true"
      if (has_rs=="1" && !rs_done) print "  - Run-status: " rs
    }
    # any item header line
    /^[[:space:]]*-[[:space:]]*\[.\]/ {
      if (in_item) { flush_stamps(); in_item=0 }
      line=$0
      is_target = (index(line, "`slug: " slug "`")>0 || index(line, "`slug:" slug "`")>0)
      if (is_target) {
        in_item=1
        # replace the [.] sentinel with the requested one
        sub(/\[.\]/, sent, line)
        print line
        next
      }
    }
    # inside the target block: replace existing stamp sub-lines in place
    in_item && /^[[:space:]]*-[[:space:]]*pr:/ {
      if (pr!="") { print "  - pr: " pr; pr_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*pushed_sha:/ {
      if (sha!="") { print "  - pushed_sha: " sha; sha_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*speculative:/ {
      if (spec=="1") { print "  - speculative: true"; spec_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*Run-status:/ {
      if (has_rs=="1") { print "  - Run-status: " rs; rs_done=1 } ; next
    }
    # leaving the block on a blank line or a new top-level construct
    in_item && (/^[^[:space:]]/ || /^[[:space:]]*$/) {
      flush_stamps(); in_item=0
    }
    { print }
    END { if (in_item) flush_stamps() }
  ' "$file" > "$tmp"

  # Derive the vault-relative path: the tail after a `/Plans/` (or vault root)
  # segment. Falls back to basename under Plans/ for a bare file.
  local vault_path
  case "$file" in
    */Plans/*) vault_path="Plans/${file##*/Plans/}" ;;
    *)         vault_path="Plans/$(basename "$file")" ;;
  esac

  # Pass the plan note's on-disk path as the filesystem-fallback target: when no
  # REST config is resolvable the seam persists the sentinel there instead of
  # failing loud (#342). rc: 0 = WRITTEN, 1 = WRITE_FAILED (loud), 3 = SKIPPED.
  local rc=0
  _plan_vault_write "$vault_path" "$tmp" "$file" || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0)
      jq -cn --arg slug "$slug" --arg sentinel "$sentinel" \
        '{outcome:"WRITTEN", slug:$slug, sentinel:$sentinel}'
      ;;
    3)
      # Soft skip: nothing was persisted, but nothing broke — zero exit so the
      # orchestrator can decide how to proceed rather than aborting the run.
      jq -cn --arg slug "$slug" \
        '{outcome:"WRITE_SKIPPED", slug:$slug, reason:"no REST config and no writable on-disk plan path — see stderr"}' >&3
      ;;
    *)
      jq -cn --arg slug "$slug" \
        '{outcome:"WRITE_FAILED", slug:$slug, error:"vault REST write failed — see stderr"}' >&3
      exit 1
      ;;
  esac
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  validate)  [ $# -eq 1 ] || usage; cmd_validate "$1" ;;
  toposort)  [ $# -eq 1 ] || usage; cmd_toposort "$1" ;;
  writeback) cmd_writeback "$@" ;;
  *) usage ;;
esac
