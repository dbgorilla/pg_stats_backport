#!/usr/bin/env bash
# Build, run the regression tests, and load real pg_dump 18 statistics output.
#
# Runs as root inside a Docker Hub postgres image, with the repo mounted at /src:
#   docker run --rm -v "$PWD:/src:ro" postgres:16-bookworm bash /src/ci/test.sh 16
set -euo pipefail

PG_MAJOR="${1:?usage: test.sh <postgres major version>}"
export DEBIAN_FRONTEND=noninteractive

echo "=== install build tools and the PostgreSQL 18 client (for pg_dump 18)"
# The image's apt source lists only its own major version; add 18 for pg_dump.
sed -i -E "s/ main( [0-9]+)+\$/ main ${PG_MAJOR} 18/" /etc/apt/sources.list.d/pgdg.list
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends \
    build-essential "postgresql-server-dev-${PG_MAJOR}" postgresql-client-18 >/dev/null

PG_BIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
PG_DUMP_18=/usr/lib/postgresql/18/bin/pg_dump

cp -r /src /build
chown -R postgres:postgres /build
cd /build

echo "=== build and install on PostgreSQL ${PG_MAJOR}"
su postgres -c "make PG_CONFIG=${PG_BIN}/pg_config"
make install PG_CONFIG="${PG_BIN}/pg_config" >/dev/null

echo "=== start a server"
su postgres -c "${PG_BIN}/initdb -D /tmp/pgdata -U postgres --auth=trust >/dev/null"
su postgres -c "${PG_BIN}/pg_ctl -D /tmp/pgdata -o '-k /tmp -c listen_addresses=' -l /tmp/pg.log -w start >/dev/null"
export PGHOST=/tmp PGUSER=postgres

echo "=== regression tests"
if ! su postgres -c "make installcheck PG_CONFIG=${PG_BIN}/pg_config PGHOST=/tmp PGUSER=postgres"; then
    cat /build/regression.diffs || true
    exit 1
fi

echo "=== dump statistics with pg_dump 18 and load them into an empty copy"
psql() { su postgres -c "psql -h /tmp -U postgres -v ON_ERROR_STOP=1 -qAtX $*"; }
psql "-c 'CREATE DATABASE src'"
psql "-c 'CREATE DATABASE dst'"
psql "-d src" <<'SQL'
CREATE TABLE orders (id int PRIMARY KEY, customer int, status text, placed date);
INSERT INTO orders
SELECT g, g % 5000, (ARRAY['new','paid','shipped','returned'])[1 + g % 4],
       date '2026-01-01' + g % 300
FROM generate_series(1, 200000) g;
CREATE INDEX ON orders (customer);
VACUUM ANALYZE orders;
SQL

su postgres -c "${PG_DUMP_18} -h /tmp -U postgres --schema-only src" > /tmp/schema.sql
su postgres -c "${PG_DUMP_18} -h /tmp -U postgres --statistics-only src" > /tmp/stats.sql
echo "pg_dump 18 wrote $(grep -c 'pg_restore_attribute_stats' /tmp/stats.sql) column and $(grep -c 'pg_restore_relation_stats' /tmp/stats.sql) relation statistics calls"

# pg_dump 18 sets transaction_timeout, which servers before 17 do not have.
# psql reports that one SET and carries on, as it would for any restore.
su postgres -c "psql -h /tmp -U postgres -qX -d dst -f /tmp/schema.sql" >/dev/null 2>/tmp/schema.err || true
if grep -v 'transaction_timeout' /tmp/schema.err | grep -q .; then
    echo "schema restore reported errors:"; cat /tmp/schema.err; exit 1
fi
psql "-d dst -c 'CREATE EXTENSION pg_stats_backport'"
su postgres -c "psql -h /tmp -U postgres -qX -d dst -f /tmp/stats.sql" >/dev/null 2>/tmp/stats.err || true
if grep -v 'transaction_timeout' /tmp/stats.err | grep -q .; then
    echo "statistics restore reported errors:"; cat /tmp/stats.err; exit 1
fi

stats_query="SELECT attname, null_frac, avg_width, n_distinct, most_common_vals::text,
                    most_common_freqs::text, histogram_bounds::text, correlation
             FROM pg_stats WHERE tablename = 'orders' ORDER BY attname"
class_query="SELECT relname, relpages, reltuples, relallvisible FROM pg_class
             WHERE relname LIKE 'orders%' ORDER BY relname"
for q in "$stats_query" "$class_query"; do
    psql "-d src" <<<"$q" > /tmp/a
    psql "-d dst" <<<"$q" > /tmp/b
    diff /tmp/a /tmp/b || { echo "statistics differ between source and copy"; exit 1; }
done
echo "column and relation statistics match the source exactly"

plan="EXPLAIN (COSTS OFF) SELECT * FROM orders WHERE customer = 42 AND placed > date '2026-06-01'"
psql "-d src" <<<"$plan" > /tmp/a
psql "-d dst" <<<"LOAD 'pg_stats_backport'; SET pg_stats_backport.use_stored_size = on; $plan" > /tmp/b
diff /tmp/a /tmp/b || { echo "plan on the empty copy differs from the source"; exit 1; }
echo "empty copy plans the same as the source:"
cat /tmp/b

su postgres -c "${PG_BIN}/pg_ctl -D /tmp/pgdata -m fast -w stop >/dev/null"
echo "=== PASSED on PostgreSQL ${PG_MAJOR}"
