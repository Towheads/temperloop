- **`cache.sh` now paginates the per-issue comments fetch** (#1820).
  `cache_refresh_details` called `issues/<n>/comments` unpaginated, so any
  issue past GitHub's default page size of 30 comments was silently truncated
  in the durable corpus store (`details/<n>.json`). The fetch now uses
  `per_page=100` + `--paginate` (the same discipline as the bulk list fetch),
  and each record is stamped `commentsPaginated: true`; records written by the
  unpaginated code lack the marker and self-heal via a one-time re-fetch on
  the next details refresh, even when their `updatedAt` is unchanged.
