# Contributing to linkrot

Small project, small rules.

1. **One issue, one change.** Every open issue names a falsifiable check in
   its acceptance section. A change is done when that check passes and the
   existing suite still does.
2. **Add the test first, or at least in the same change.** Every issue here
   exists because the suite does not cover the behaviour yet. Fixing the code
   without adding the case leaves the next regression undetected.
3. **Keep `linkrot.py` readable over clever.** It is one module on purpose.
   If a change needs a second module, say so in the pull request rather than
   sneaking the split in.
4. **Run the suite before you push:**

   ```
   python3 -m unittest discover -s . -p 'test_*.py'
   ```

Docs count as code here: if a change alters what `linkrot` does, the
[README](README.md) and [the walkthrough](docs/getting-started.md) have to
say the same thing afterwards.
