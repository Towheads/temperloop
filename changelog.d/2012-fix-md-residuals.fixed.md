- **`/fix` no longer drops the open-question flag off an issue it turns out it
  cannot drive** (#2012). When `/fix` asks you about an issue's open question,
  it clears that question's label the moment you answer — and then re-checks
  the saved build before driving. If that check says the build cannot be safely
  driven over (it holds edits nobody has committed, or the check could not read
  it at all), `/fix` stops. Previously it stopped there and only reported, so
  the issue went back into the pool with its open question no longer recorded
  anywhere, and the next run picked it up as if the question had been settled.
  It now runs the same parking sequence every other stop uses: your answer and
  the saved build's path go on the issue as a comment, and the open-question
  label and assignment go back on. `claude/commands/fix.md` states the sequence
  once and every stop points at it by name.
