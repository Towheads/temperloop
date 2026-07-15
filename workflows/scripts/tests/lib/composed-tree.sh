#!/usr/bin/env bash
#
# composed-tree.sh — shared "composed overlay tree, or standalone kernel
# checkout?" detection for the suites that bootstrap a real temperloop.
#
# WHY THIS EXISTS. Every gate that calls sandbox_bootstrap_checkout
# (test_install_lifecycle.sh, test_sandbox.sh legs 4-5,
# test_sandbox_dry_run_legs.sh, test_install_cli.sh) inherits a HARD
# PRECONDITION, not a preference: that function bare-clones $REPO_ROOT over
# file:// and runs its bin/bootstrap.sh. A composed overlay tree (foundation,
# stageFind, ssmobile, subsetwiki) vendors the kernel at kernel/ and has no
# bin/ of its own, and a vendored subtree path is not clonable at all — so
# those suites self-scope to a kernel-only checkout and skip elsewhere.
#
# temperloop#267 introduced this detection inline in test_install_lifecycle.sh.
# temperloop#361 found the same three arms were needed by three more suites
# (which instead hard-failed on a composed tree with a bare
# "bin/bootstrap.sh not found", blocking foundation's v0.12.0 vendor), so the
# predicate lives here once rather than as four copies free to drift.
#
# Side-effect free by contract: this file defines one function and does nothing
# else — no temp dirs, no env mutation — so it is safe to source BEFORE any
# sandbox setup. That preserves the fast-exit property temperloop#267 requires
# ("a composed-tree run exits 0 fast with zero sandbox setup").
#
# Usage:
#   . "<path>/lib/composed-tree.sh"
#   if _reason="$(composed_tree_reason "$REPO_ROOT")"; then
#     echo "SKIP: <suite> — composed overlay tree detected ($_reason)."
#     exit 0
#   fi

# composed_tree_reason <repo_root>
#   Prints a human-readable reason and returns 0 when <repo_root> is a composed
#   overlay tree; prints nothing and returns 1 when it is a standalone
#   kernel-only checkout.
#
# Three independent signals (any one fires -> composed):
#   1. claude/CLAUDE.overlay.md present beside claude/CLAUDE.kernel.md — the
#      same idiom workflows/scripts/validate-live-drain.sh's own KERNEL_ONLY_MD
#      check uses (composed = overlay present).
#   2. A kernel/ subtree at the repo root that is itself recognizably a vendored
#      kernel checkout (carries bin/temperloop or claude/CLAUDE.kernel.md) — the
#      "vendored at foundation/kernel/" layout. Gated on a marker file rather
#      than bare directory presence, so an unrelated repo with its own
#      top-level kernel/ directory does not false-positive.
#   3. The caller IS the vendored copy: <repo_root> (derived from BASH_SOURCE,
#      so it points at the kernel subtree itself when the suite lives at
#      <overlay>/kernel/workflows/scripts/tests/) is not its own git toplevel —
#      the kernel tree is embedded in a larger repo. Arms 1 and 2 cannot see
#      this case from inside the subtree. Fail-open: if git is unavailable or
#      errors, this arm stays silent and the suite runs (a standalone kernel
#      checkout in CI is always its own toplevel).
composed_tree_reason() {
  local repo_root="$1"
  local claude_md_kernel="$repo_root/claude/CLAUDE.kernel.md"
  local claude_md_overlay="$repo_root/claude/CLAUDE.overlay.md"
  local kernel_subtree="$repo_root/kernel"
  local git_toplevel repo_root_phys toplevel_phys

  if [ -f "$claude_md_kernel" ] && [ -f "$claude_md_overlay" ]; then
    printf '%s' "claude/CLAUDE.overlay.md is present beside claude/CLAUDE.kernel.md under $repo_root/claude"
    return 0
  fi

  if [ -d "$kernel_subtree" ] && { [ -f "$kernel_subtree/bin/temperloop" ] || [ -f "$kernel_subtree/claude/CLAUDE.kernel.md" ]; }; then
    printf '%s' "a kernel/ subtree is vendored at the repo root ($kernel_subtree)"
    return 0
  fi

  git_toplevel="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_toplevel" ]; then
    # Physical-path both sides (cd -P) before comparing — on macOS, $TMPDIR and
    # /var symlinks make string comparison of logical paths unreliable.
    repo_root_phys="$(cd -P "$repo_root" 2>/dev/null && pwd)"
    toplevel_phys="$(cd -P "$git_toplevel" 2>/dev/null && pwd)"
    if [ -n "$repo_root_phys" ] && [ -n "$toplevel_phys" ] && [ "$repo_root_phys" != "$toplevel_phys" ]; then
      printf '%s' "this suite's own tree ($repo_root) is a vendored subtree inside a larger repo ($git_toplevel), not a standalone kernel checkout"
      return 0
    fi
  fi

  return 1
}
