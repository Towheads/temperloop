- **Two published contract documents corrected to match the code they
  document, both found by a spike measuring detection shapes rather than by
  review or CI** (#1495):
  - `workflows/scripts/lib/knowledge_store.contract.md` claimed "there is no
    second path setting" for the store root. `ks_root()` in
    `knowledge_store.sh` has, since temperloop#1328, resolved an unset
    `KNOWLEDGE_STORE_ROOT` through `_ks_machine_conf_root()` — a
    machine-local config file read — before falling back to the XDG
    default. The doc now states that precedence explicitly.
  - `workflows/scripts/lib/tracker.contract.md` documented
    `board_sub_issues <N> <issue#>` as taking two arguments. `board_sub_issues()`
    in `board.sh` has, since temperloop#1119, taken an optional third
    `[all|open|closed]` state-filter argument defaulting to `all`. The doc
    now shows the real arity.
