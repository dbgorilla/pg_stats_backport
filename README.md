# pg_stats_backport

PostgreSQL 18 can dump and load planner statistics: `pg_dump --statistics-only`
writes them as calls to `pg_restore_relation_stats()` and
`pg_restore_attribute_stats()`. Those functions exist only in 18.

This extension adds them, unchanged from PostgreSQL 18, to PostgreSQL 13, 14, 15,
16 and 17. Statistics written by pg_dump 18 can then be loaded on those versions.

Uses:

- Reproduce a production query plan on a copy without copying the data.
- Keep plans stable across a dump and restore, without waiting for `ANALYZE`.
- Test how a query plans against statistics you write by hand.

## What you get

| | 13 to 17 | 18 |
|---|---|---|
| `pg_restore_relation_stats`, `pg_restore_attribute_stats` | added by the extension | built in |
| `pg_clear_relation_stats`, `pg_clear_attribute_stats` | added by the extension | built in |
| Planner setting `pg_stats_backport.use_stored_size` | yes | yes |

The functions are PostgreSQL 18.6's own code, with small patches so they compile
on older versions. They behave as they do in 18, including warnings for bad
values and the permission checks.

## Install

You need the server development headers for your version (`postgresql-server-dev-16`
on Debian and Ubuntu, `postgresql16-devel` on Red Hat).

```sh
make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
```

Then, as a superuser, in each database that will receive statistics:

```sql
CREATE EXTENSION pg_stats_backport;
```

On 18 this creates nothing, so the same restore script works on every version.

## Example: copy statistics from a 16 server to an empty 16 database

pg_dump 18 can read statistics from older servers.

```sh
pg_dump  -h prod --schema-only     shop | psql -h test shop_copy
psql     -h test -c 'CREATE EXTENSION pg_stats_backport' shop_copy
pg_dump  -h prod --statistics-only shop > stats.sql      # pg_dump from PostgreSQL 18
psql     -h test -f stats.sql shop_copy
```

pg_dump 18 output sets `transaction_timeout`, which servers before 17 do not
have. psql reports that line as an error and carries on; nothing else fails.

## Plan an empty table with its stored size

The planner does not use the stored row count as is. It reads the real size of
the table on disk and scales the stored row density to it. A table with restored
statistics but no data therefore still plans as empty.

The setting `pg_stats_backport.use_stored_size` fixes that. When on, the planner
uses the stored page count, row count and visible fraction for each table and
index. Tables never analyzed are left alone.

It is **off by default**. Turn it on only on a database whose data is not there,
or is not current. On a normal database it would make the planner trust stale
statistics over the real table.

The setting lives in the extension's library, so load the library first:

```sql
LOAD 'pg_stats_backport';
SET pg_stats_backport.use_stored_size = on;
EXPLAIN SELECT * FROM orders WHERE customer = 42;
```

To enable it in every session, add `pg_stats_backport` to
`session_preload_libraries` or `shared_preload_libraries` and set
`pg_stats_backport.use_stored_size = on` in `postgresql.conf` or with
`ALTER DATABASE ... SET`.

## Differences from PostgreSQL 18

- `relallfrozen` exists only on 18. Before 18 the argument is accepted and ignored.
- 18 lets a role with the `MAINTAIN` privilege set statistics. `MAINTAIN` is new in
  17, so on 13 to 16 the role must own the table or the database, as for `ANALYZE`.
- On 13, "never analyzed" is stored as a row count of 0 rather than -1, as 13 expects.

## Tests

`ci/test.sh` builds the extension, runs the regression tests in `test/`, and
dumps statistics with pg_dump 18 from a real table and loads them into an empty
copy. It checks that the copy's statistics match and that it plans the same
query the same way. `ci/memcheck.sh` runs the clang static analyzer and runs the
code under Valgrind. Both run in the Docker Hub `postgres` images:

```sh
docker run --rm -v "$PWD:/src:ro" postgres:16-bookworm bash /src/ci/test.sh 16
docker run --rm -v "$PWD:/src:ro" postgres:16-bookworm bash /src/ci/memcheck.sh 16
```

CI runs both on 13, 14, 15, 16, 17 and 18.

## Updating the PostgreSQL code

`vendor/` holds three files from `src/backend/statistics/` and one header from
`src/include/statistics/`, taken from tag `REL_18_6`. Every change to them is
marked with a `pg_stats_backport:` comment. To move to a newer tag, download the
four files and apply the marked changes again:

```sh
TAG=REL_18_6
base=https://raw.githubusercontent.com/postgres/postgres/$TAG/src
for f in attribute_stats.c relation_stats.c stat_utils.c; do
  curl -fsSL "$base/backend/statistics/$f" -o "vendor/$f"
done
curl -fsSL "$base/include/statistics/stat_utils.h" -o vendor/statistics/stat_utils.h
```

## License

PostgreSQL License. See `LICENSE`. The code in `vendor/` is copyright the
PostgreSQL Global Development Group.
