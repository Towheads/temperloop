- **`session-start-drain.sh` writes session stubs through the knowledge_store
  seam instead of a raw `curl` PUT** (#732). The SessionStart drain hook used
  to build its own Obsidian Local REST API request — read the plugin's API key
  file, `PUT /vault/Sessions/_inbox/<stub>`, branch on the HTTP code — which
  meant a stranger's plain-files install could never drain a stub at all: no
  Obsidian vault, no REST plugin, no key file, so every run fell open at
  "API key file missing". The write is now one `ks_write "Sessions/_inbox/…"`
  call and `KNOWLEDGE_STORE_BACKEND` decides the transport: `plain-files`
  (the default) writes atomically under `ks_root`, and `obsidian` reaches the
  same `PUT /vault/<path>` the hook used to hand-roll, so an Obsidian-backed
  install keeps its existing wire behaviour. `KS_LIB_DIR` resolution
  (temperloop#406, hook lib-path resolution) and the
  fail-open-when-the-seam-is-unreachable posture are unchanged.

  The stub search now prunes **two** store roots rather than one: `ks_root`
  (the plain-files root) and the vault the Obsidian key-file path names, each
  with trailing slashes stripped. Both halves are load-bearing — `find -path`
  never matches a trailing-slashed operand, and under the `obsidian` backend
  `ks_root` is documented as meaningless, so either gap let a `.mind/` file
  sitting inside the store be drained back into the store and deleted from
  source.
