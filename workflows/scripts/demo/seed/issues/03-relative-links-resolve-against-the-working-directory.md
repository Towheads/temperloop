# Relative links resolve against the working directory, not the file

`check_file()` calls `os.path.exists(target)` on the raw target string. That
resolves the target against the process's current working directory instead
of against the directory the Markdown file lives in, so the same document
reports different results depending on where you happen to run the tool.

Repro:

```
$ (cd docs && python3 ../linkrot.py . | grep -c 'README')
0
$ python3 linkrot.py docs | grep 'README'
broken: docs/getting-started.md -> ../README.md
```

`docs/getting-started.md` links to `../README.md`, which exists. Both runs
should agree, and both should say nothing about it.

Expected: a relative target is resolved against `os.path.dirname()` of the
file that contains it, so a report is independent of the working directory.

Note the existing suite does not catch this because `CheckFileTest` chdirs
into its temporary directory before writing a file at the top of it — every
relative target happens to resolve either way. A regression test has to place
the document in a subdirectory and scan from the parent.

Acceptance (falsifiable):

- scanning a tree from its root and from a subdirectory produces the same
  findings for the same document
- `python3 linkrot.py .` does not report `../README.md`
- the suite gains a case that writes `docs/page.md` linking to `../top.md`
  and asserts no finding, without chdiring into `docs/`
