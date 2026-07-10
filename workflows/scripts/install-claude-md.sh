#!/usr/bin/env bash
#
# install-claude-md.sh — compose ~/.claude/CLAUDE.md from the kernel contracts
# doc + the personal overlay include + a rendered knowledge-store-routing
# section (foundation #781-ish, Epic B "layered CLAUDE.md").
#
# Why this exists: claude/CLAUDE.md used to be a single file, symlinked
# straight to ~/.claude/CLAUDE.md by `make install-claude` (exactly like every
# other claude/* entry). The kernel/overlay split needs TWO tracked sources —
# claude/CLAUDE.kernel.md (shippable, generic process rules a stranger's
# install would need) and claude/CLAUDE.overlay.md (Travis's personal/org/
# machine-specific rules) — and a symlink can't compose two files into one.
# So, exactly like install-settings.sh does for the #292 settings.json
# reconcile, this script GENERATES a real file instead of symlinking one.
#
#   install-claude-md.sh <kernel.md> <overlay.md> <target-path>
#
# Composition, in order:
#   1. a generated-file banner (naming both sources — never hand-edit the
#      target; edit the sources and re-run `make install-claude`)
#   2. the kernel doc, with any `{{KNOB_NAME}}` placeholder tokens it contains
#      substituted for a value resolved from config (see "Prose-resident knob
#      rendering" below) — otherwise verbatim
#   3. a rendered "## Knowledge store routing" section (see below)
#   4. the overlay doc, verbatim
#
# ── Knowledge store routing (foundation #781, the Epic B counterpart to Epic
#    A's knowledge_store seams, #762) ─────────────────────────────────────
# Neither source file hand-types the store root, the script-plane backend
# name, or the MCP-vs-Read access rule — all three are resolved HERE, at
# compose time, from the same config seams the script plane already reads
# (workflows/scripts/build/build.config.sh for KNOWLEDGE_STORE_ROOT,
# workflows/scripts/lib/knowledge_store.sh for the KNOWLEDGE_STORE_BACKEND
# default), so there is exactly one place either value is typed.
#
# The agent-plane MCP-vs-Read choice does NOT simply mirror
# KNOWLEDGE_STORE_BACKEND — per knowledge_store.contract.md's "Obsidian-mode
# note", the agent plane stays on Obsidian's own MCP tools whenever the store
# root actually IS an Obsidian vault, independent of which script-plane
# backend is configured (Travis's KNOWLEDGE_STORE_BACKEND defaults to
# plain-files today even though his root is his real vault — the script-plane
# routing is still incremental per Epic A). So the access rule is rendered
# from a MECHANICAL, install-time probe — does `<root>/.obsidian` exist? —
# not from the KNOWLEDGE_STORE_BACKEND value alone. This is the same kind of
# "read real machine state at render time" move install-settings.sh already
# makes for the local `model` field.
#
# This script is idempotent: composing the same sources twice, on the same
# machine, byte-for-byte reproduces the same target (no timestamps or other
# non-deterministic content are rendered in).
set -euo pipefail

kernel="${1:?usage: install-claude-md.sh <kernel.md> <overlay.md> <target-path>}"
overlay="${2:?usage: install-claude-md.sh <kernel.md> <overlay.md> <target-path>}"
target="${3:?usage: install-claude-md.sh <kernel.md> <overlay.md> <target-path>}"

[ -f "$kernel" ]  || { echo "install-claude-md: kernel doc not found: $kernel" >&2; exit 1; }
[ -f "$overlay" ] || { echo "install-claude-md: overlay doc not found: $overlay" >&2; exit 1; }

# FOUNDATION root, derived from the kernel doc's path (claude/CLAUDE.kernel.md
# -> repo root), so this script works regardless of caller CWD.
foundation="$(cd "$(dirname "$kernel")/.." && pwd)"
build_config="${foundation}/workflows/scripts/build/build.config.sh"
ks_lib="${foundation}/workflows/scripts/lib/knowledge_store.sh"

# ---------------------------------------------------------------------------
# ── Prose-resident knob rendering (temperloop#183, D3's "CLAUDE.md-resident
#    knob" seam — claude/CLAUDE.kernel.md § Prose-resident knob convention) ──
# A knob embedded in this file's own standing-rules prose (e.g. the WIP cap)
# has no Step-0 to source a config file from — the doc is read passively by
# the agent, never executed — so it is rendered here instead, at compose
# time, into a `{{KNOB_NAME}}` placeholder token the kernel doc's own text
# carries. SAME mechanism as § Knowledge store routing below (resolve a
# value from build.config.sh in an isolated subshell, then substitute it into
# the composed output) — this is one more resolved value fed through that
# existing render pass, not a second templating engine.
#
# render_kernel_doc <kernel-file> — prints the kernel doc's content with every
# known `{{KNOB_NAME}}` token substituted; unmatched tokens are left as-is
# (surfacing a missing wiring loudly rather than silently blanking the knob).
# ---------------------------------------------------------------------------
render_kernel_doc() {
  local kernel_file="$1" content wip_cap

  wip_cap=""
  if [ -f "$build_config" ]; then
    wip_cap="$(
      set -e
      # shellcheck source=/dev/null
      source "$build_config"
      printf '%s\n' "$FUNNEL_WIP_CAP"
    )" || wip_cap=""
  fi
  [ -n "$wip_cap" ] || wip_cap=3   # build.config.sh's own default, if unresolved

  content="$(cat "$kernel_file")"
  content="${content//\{\{WIP_CAP\}\}/$wip_cap}"
  printf '%s' "$content"
}

# ---------------------------------------------------------------------------
# render_knowledge_routing — prints the "## Knowledge store routing" section.
# ---------------------------------------------------------------------------
render_knowledge_routing() {
  local root="" backend="" access_rule=""

  if [ -f "$build_config" ] && [ -f "$ks_lib" ]; then
    # Resolve KNOWLEDGE_STORE_ROOT / KNOWLEDGE_STORE_BACKEND in an isolated
    # subshell so their `:=` defaults (and build.config.sh's optional
    # gitignored build.config.local.sh) never leak into THIS script's own
    # environment or clobber a caller's exported values.
    local resolved
    resolved="$(
      set -e
      # shellcheck source=/dev/null
      source "$build_config"
      # shellcheck source=/dev/null
      source "$ks_lib"
      printf '%s\n%s\n' "$(ks_root)" "$KNOWLEDGE_STORE_BACKEND"
    )" || resolved=""
    root="$(sed -n '1p' <<<"$resolved")"
    backend="$(sed -n '2p' <<<"$resolved")"
  fi

  if [ -z "$root" ]; then
    root="(unresolved — workflows/scripts/build/build.config.sh or workflows/scripts/lib/knowledge_store.sh not found under $foundation)"
    backend="(unresolved)"
    access_rule="Could not resolve the knowledge_store config at compose time — treat this section as stale and re-run \`make install-claude\` from a full foundation checkout."
  elif [ -d "${root}/.obsidian" ]; then
    access_rule="The store root is an Obsidian vault (a \`.obsidian\` directory is present at \`${root}\`) — always route through the Obsidian MCP tools (\`mcp__obsidian-builtin__*\` for read/write/patch, \`mcp__obsidian__search_vault_smart\` for semantic search); never \`Read\`/\`Bash\`/\`find\` it directly. See § Obsidian vault."
  else
    access_rule="No Obsidian vault detected at the store root (no \`.obsidian\` directory at \`${root}\`) — access it directly via \`Read\`/\`Write\`/\`Grep\`; there is no MCP layer to route through."
  fi

  cat <<EOF
## Knowledge store routing

Rendered at compose time (\`make install-claude\` → \`workflows/scripts/install-claude-md.sh\`) from \`workflows/scripts/build/build.config.sh\` (\`KNOWLEDGE_STORE_ROOT\`) and \`workflows/scripts/lib/knowledge_store.sh\` (\`KNOWLEDGE_STORE_BACKEND\`, \`ks_root\`) — do not hand-edit this section in either source doc; edit the config seam instead and re-run \`make install-claude\`. See \`workflows/scripts/lib/knowledge_store.contract.md\` for the full interface.

- **Store root**: \`${root}\`
- **Script-plane backend** (\`KNOWLEDGE_STORE_BACKEND\`, document I/O for hooks/scripts): \`${backend}\`
- **Agent-plane access rule** (this session, reading/writing the store directly): ${access_rule}
EOF
}

tmp="$(mktemp "${TMPDIR:-/tmp}/install-claude-md.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  printf '<!-- GENERATED by foundation '"'"'make install-claude'"'"' — DO NOT EDIT HERE.\n'
  printf '     Sources: claude/CLAUDE.kernel.md + claude/CLAUDE.overlay.md\n'
  printf '     (the "## Knowledge store routing" section below is rendered, not\n'
  printf '     tracked in either source). Edit the sources, then re-run\n'
  # shellcheck disable=SC2016  # literal markdown backticks, not expansion
  printf '     `make install-claude`. See workflows/scripts/install-claude-md.sh. -->\n'
  printf '\n'
  render_kernel_doc "$kernel"
  printf '\n'
  render_knowledge_routing
  printf '\n'
  cat "$overlay"
} >"$tmp"

# Replace as a REAL file — drop any prior symlink first so the move can't
# write through it back into a tracked source (same discipline as
# install-settings.sh's #292 reconcile).
rm -f "$target"
mv -f "$tmp" "$target"
trap - EXIT
