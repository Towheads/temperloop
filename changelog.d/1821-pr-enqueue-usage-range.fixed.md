- **`pr-enqueue --help` no longer leaks `set -euo pipefail` into the usage
  text** (#1821). The usage printer's hardcoded sed line range (`2,60p`) was
  off by one against the header comment block; it now prints the header
  structurally — every comment line after the shebang, stopping at the first
  non-comment line — so header growth or shrink can never re-introduce the
  leak. A regression test asserts `--help` ends at the header's exit-status
  lines with no trailing code line.
