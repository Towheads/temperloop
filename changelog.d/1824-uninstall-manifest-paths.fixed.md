- **`temperloop uninstall` now fails loudly when the manifest's `.paths` cannot
  be read, instead of reporting `done (no-op)`** (#1824). `manifest_load`
  validates that `.paths` exists and is an object — a malformed manifest
  (missing `.paths`, `null`, an array, or a string) is refused with a message
  naming the problem and a non-zero exit, so a manifest the build never
  actually understood can no longer read as "nothing was ever installed".
  `uninstall.sh` also checks the exit status of its `.paths` enumeration
  (previously discarded by a process substitution) as a second belt. A
  genuinely-empty `{}` paths object remains the legitimate no-op state.
