# Anchor-only links like `#usage` are reported as broken

`is_local()` in `linkrot.py` returns `True` for every link target, so an
anchor that points inside the same document is treated as a file path and
then reported as missing.

Repro:

```
$ python3 linkrot.py docs | grep '#'
broken: docs/getting-started.md -> #an-example-run
```

`#an-example-run` is a heading in that same file. It is not a path, it cannot
resolve to a file, and it must never appear in the report.

Expected: anchor-only targets are classified as not-a-file and skipped before
the existence check runs.

Acceptance (falsifiable):

- `linkrot.is_local("#usage")` returns a falsey value
- `check_file()` on a document whose only link is `[x](#usage)` returns `[]`
- `python3 -m unittest discover -s . -p 'test_*.py'` stays green, and the
  suite gains a case covering an anchor-only target

Related: issue "External URLs are reported as broken" is the same
classification gap seen from the other side — the two are worth deciding
together before either is coded.
