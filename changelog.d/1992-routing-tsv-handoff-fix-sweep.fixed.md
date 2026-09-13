- **The reviewer-routing fix now covers `/fix` and `/sweep`, not just `/build`**
  (#1992). #1982 stopped the reviewer-routing table being copied back out of
  the build machinery — the caller reads the file and hands its contents in
  instead — but only `/build` was updated to do so. `/fix` and `/sweep` drive
  the same machinery and were still on the old, unreliable copying path, so the
  same three mangled shapes (empty, a sentence describing the table, tabs and
  line breaks turned into literal backslash characters) could still stall a
  change with no review having run. Both now read the table themselves and pass
  it in. This matters most for `/sweep`, which runs unattended by default —
  there the stall happens with nobody watching. If the file cannot be read,
  both omit it and the existing fallback path stands, so neither ever stops on
  this. **No routing behavior changes** — the same table produces the same
  reviewers.
