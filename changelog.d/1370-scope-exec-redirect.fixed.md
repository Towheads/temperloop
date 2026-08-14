- **`validate-model-usage-emit.sh`'s stderr no longer goes silent after it
  opens a lake file to read.** The open used a bare `exec 3< "$src"
  2>/dev/null` — `exec` with no command word applies its redirects
  PERMANENTLY to the current shell once the open succeeds, which was quietly
  redirecting the validator's own stderr to `/dev/null` for the rest of the
  run. On the failure path this was harmless (bash stops at the first failed
  redirection, so the `CANNOT EVALUATE` message still printed) and the one
  surviving stderr writer already carried its own `2>/dev/null` — but any
  future diagnostic added after that line would have vanished with no test
  failure to catch it (temperloop#1370). The open is now scoped with a
  command group, `{ exec 3< "$src"; } 2>/dev/null`, matching the idiom
  `workflows/scripts/model-comparison/tagging.sh:357` already uses (and
  documents) for the identical hazard — the `2>/dev/null` now applies only to
  the open attempt, not to the shell for the remainder of the script. A
  repo-wide sweep confirms this was the only bare `exec N< ... 2>/dev/null`
  site left in the tree.
