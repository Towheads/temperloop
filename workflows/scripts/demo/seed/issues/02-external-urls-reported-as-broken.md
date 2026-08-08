# External URLs are reported as broken

The same classification gap as the anchor case: `is_local()` returns `True`
unconditionally, so `https://commonmark.org/` is passed to the existence
check as if it were a relative path, and duly reported as missing.

Repro:

```
$ python3 linkrot.py docs | grep '://'
broken: docs/getting-started.md -> https://commonmark.org/
```

Expected: targets carrying a URL scheme (`http:`, `https:`, `mailto:`, and
anything else of that shape) are not files, are not checkable by this tool,
and are skipped.

Deliberately out of scope: actually fetching an external URL to see whether
it still resolves. `linkrot` checks the repository, not the internet — if we
ever want that it is a separate, opt-in capability with a very different cost
profile.

Acceptance (falsifiable):

- `linkrot.is_local("https://example.com/")` returns a falsey value
- `linkrot.is_local("mailto:someone@example.com")` returns a falsey value
- `python3 linkrot.py .` reports no target containing `://`
- the suite gains a case covering an external target and stays green

Related: issue "Anchor-only links like `#usage` are reported as broken".
