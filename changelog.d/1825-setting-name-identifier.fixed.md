- **The setting registry now validates that every setting name is a legal
  shell identifier** (`[A-Za-z_][A-Za-z0-9_]*`), and `temperloop config list`
  refuses loudly (exit 1, a `MALFORMED` diagnostic naming the row and its
  source file) when the kernel table or an operator-authored
  `setting-registry.overlay.tsv` carries an illegal name — e.g. hyphenated or
  leading-digit (#1825). Previously such a row slipped through
  `setting_registry_validate` and the `${!name}` indirect-expansion sites in
  `config list` silently dropped it while still exiting 0. Other
  malformations (unknown type/layer, bad op) keep the existing
  warn-and-continue best-effort union, but the diagnostics are now printed to
  stderr instead of being swallowed.
