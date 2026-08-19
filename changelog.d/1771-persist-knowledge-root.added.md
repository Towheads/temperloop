- **`temperloop install` now persists and verifies the knowledge-store root
  instead of leaving it to an untracked, operator-created file** (#1771). The
  rung-3 machine conf that `ks_root()` reads through `_ks_machine_conf_root`
  was written, installed and verified by nothing in this tree, so losing it
  dropped every consumer onto the XDG default — and because the plain-files
  backend's append does `mkdir -p`, the wrong root was silently *created* and
  written to rather than erroring. The install path now owns it, via
  `links_persist_knowledge_root` (`workflows/scripts/install/links.sh`), which
  **never guesses a root**: with an absolute `KNOWLEDGE_STORE_ROOT` in the
  install-time environment and no usable conf root, it appends
  `: "${KNOWLEDGE_STORE_ROOT:=<value>}"` to the conf (creating the file with a
  header when absent), so a value that was only ever an ephemeral env var
  becomes something a bare hook or launchd agent resolves too. A conf that
  already yields a usable absolute root is left byte-identical, which is also
  what makes a second install a no-op; a relative root is refused by name
  (`_ks_machine_conf_root` would reject it, so persisting one would be a
  silent no-op); and a conf that already *mentions* `KNOWLEDGE_STORE_ROOT`
  unusably is reported rather than appended behind (dead text) or rewritten (a
  clobber). With nothing configuring the root at all, the install prints the
  `default-fallback` / `conf-present-but-unusable` notice — the same
  provenance vocabulary `doctor.sh`'s `check_knowledge_root` established in
  #1340 — naming the root every consumer would otherwise use, and does **not**
  fail: a fresh install legitimately has no store yet. The conf is
  deliberately not manifest-managed, so `temperloop uninstall` never removes
  it, exactly as it never removes the store itself.
