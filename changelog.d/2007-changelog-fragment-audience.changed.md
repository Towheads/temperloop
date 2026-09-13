- **`changelog.d/README.md` now states who a changelog entry is written for,
  and the register that follows from it** (#2007). Fragments were being
  written for the person who had just made the change — leaning on step
  letters from a command spec, field names from an implementation file, and
  in one case a mechanism name that existed nowhere in the tree — and then
  folded verbatim into `CHANGELOG.md`, which is read by someone holding none
  of that context. The README now names that reader (the adopter deciding
  whether and how to pull an update), gives three concrete do-not rules, and
  shows a bad/good pair for each, drawn from real review findings. It also
  records the finding rate that prompted it, so the next check is a
  comparison rather than an impression. No gate or command behaviour
  changed: if you write changelog entries for this repo, read that file
  before the next one.
