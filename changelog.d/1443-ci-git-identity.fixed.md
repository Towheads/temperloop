- **The tier-2 install round trip no longer dies at the proposal commit for
  want of a git identity, and the generator now says so in words.** A GitHub
  Actions runner ships with no `user.name`/`user.email`, and
  `workflows/scripts/proposal/proposal-pr.sh` commits the proposed tree before
  pushing it — so `install-tier2.yml`'s `init` leg failed with a raw "Author
  identity unknown / fatal: empty ident name" buried inside a JSON `error`
  string, after the proposal branch had already been cut. Two fixes, at two
  altitudes. The workflow configures the standard `github-actions[bot]`
  identity in a step of its own before the round trip. And the generator now
  **preflights** the identity before it touches the checkout: if neither
  `git config user.name`/`user.email` nor git's own
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` resolution yields one, it refuses with the
  usual structured `ERROR` outcome *plus* a plain-text remedy on stderr naming
  the exact two `git config --global` commands to run. It never invents an
  identity — authoring an adopter's first commit as someone they never chose
  is worse than a clear refusal — and because it refuses before the
  `checkout -B`, the checkout is no longer left stranded on a half-built
  proposal branch.
