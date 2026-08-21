- **The knowledge-search backend home is now a declared, disclosed removal
  scope — and `test_install_lifecycle.sh` returns the same verdict with or
  without `uv` on the host** (temperloop#1658). Since temperloop#1113 the
  pinned `basic-memory` tool is *installed* rather than resolved per run,
  which materialises a full virtualenv (plus uv's cache, any managed CPython
  it downloaded, and the derived search index) under
  `${KNOWLEDGE_SEARCH_BM_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}`.
  Nothing recorded it, `temperloop uninstall` never removed it, and no
  removal surface named it — so case 7c failed on every workstation with
  `uv` while CI, which has none, stayed green and never exercised the path at
  all. The tree now has an explicit disposition: **deliberately unmanaged,
  regenerable tool state** — scope **(g)** of `bin/README.md` § Uninstall,
  alongside the issue-cache store root it most resembles. `temperloop
  uninstall` names the tree and prints its exact `rm -rf` whenever it is on
  disk (and stays silent when it is not, since a host without `uv` never
  grows one), honoring an explicit `KNOWLEDGE_SEARCH_BM_HOME`; the lifecycle
  suite's new case **7f** fails if the tree survives uninstall and the
  uninstall output did not name it, so the 7c exclusion cannot quietly become
  an *undisclosed* one.
