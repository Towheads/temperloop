- **The reviewer-routing table is now supplied by the caller instead of being
  copied back out of the build machinery** (#1982). Deciding which review
  agents a change needs requires two inputs: the list of files the change
  touched, and the routing table that maps file types to reviewers. Only the
  first genuinely has to be discovered while the build runs — the routing
  table is a fixed file in the repo, the same on every run. It was
  nevertheless being read inside the build and copied back out through an
  intermediate step, and that copy was unreliable: across eight observed
  occurrences it arrived empty, arrived as a sentence *describing* the table
  rather than the table, and arrived with its tab and line breaks turned into
  literal backslash characters so that eleven rows parsed as one. Each failure
  stalled the change with no review having run, and four of them landed
  consecutively on a single change. A count and a checksum sent alongside the
  table were correct every time, which is what identified the copying step —
  not the reading of the file — as the fault. The caller now reads the file
  directly and passes its contents in, so the unreliable copy is no longer
  part of the path. Earlier attempts guarded the copy (a row count, then a
  content checksum, then one automatic retry); those guards remain as a
  fallback for a caller that has not been updated, and nothing changes for
  such a caller. **No routing behavior changes** — the same table produces the
  same reviewers; only how it reaches the decision changes.
