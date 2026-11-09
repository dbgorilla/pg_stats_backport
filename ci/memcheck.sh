#!/usr/bin/env bash
# Memory checks for the extension's C code: the clang static analyzer over the
# build, then the server under Valgrind running every code path.
#
# Runs as root inside a Docker Hub postgres image, with the repo mounted at /src:
#   docker run --rm -v "$PWD:/src:ro" postgres:15-bookworm bash /src/ci/memcheck.sh 15
#
# Stock PostgreSQL builds leak a fixed amount at backend exit. Those reports
# never name this repo's source files, so the check fails only on a Valgrind
# report whose backtrace does.
set -euo pipefail

PG_MAJOR="${1:?usage: memcheck.sh <postgres major version>}"
PG_BIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
# The escaped ".c" matters: Valgrind's header echoes the library name
# pg_stats_backport without ".c", and that must not match.
OUR_SOURCES='attribute_stats\.c|relation_stats\.c|stat_utils\.c|pg_stats_backport\.c'

echo "=== install build tools, clang analyzer and Valgrind"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends \
    build-essential clang clang-tools valgrind "postgresql-server-dev-${PG_MAJOR}" >/dev/null

cp -r /src /build && cd /build

echo "=== [1/2] clang static analyzer"
scan-build --status-bugs -o /tmp/scan --use-analyzer=/usr/bin/clang \
    make PG_CONFIG="${PG_BIN}/pg_config" CC=clang
make -s clean PG_CONFIG="${PG_BIN}/pg_config" >/dev/null

echo "=== [2/2] Valgrind"
# -O0 -g so a Valgrind backtrace points at a readable source line.
make -s CC=cc COPT="-O0 -g" PG_CONFIG="${PG_BIN}/pg_config" >/dev/null
make -s install PG_CONFIG="${PG_BIN}/pg_config" >/dev/null
export PATH="${PG_BIN}:$PATH"

su postgres -c "initdb -D /tmp/pg -U postgres --auth=trust -E UTF8 >/dev/null 2>&1"
rm -f /tmp/vg.*.log
su postgres -c "valgrind --trace-children=yes --leak-check=full --track-origins=yes \
    --num-callers=30 --error-exitcode=0 --log-file=/tmp/vg.%p.log \
    postgres -D /tmp/pg -c session_preload_libraries=pg_stats_backport \
    -c pg_stats_backport.use_stored_size=on \
    -c listen_addresses=127.0.0.1 -c shared_buffers=16MB -c fsync=off -c max_connections=8 \
    >/tmp/pg.log 2>&1 &"
for _ in $(seq 1 300); do pg_isready -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 2; done
pg_isready -h 127.0.0.1 >/dev/null || { echo "postgres did not start under Valgrind"; tail -30 /tmp/pg.log; exit 1; }

# Relation restore, the planner hook (EXPLAIN), and a column restore.
su postgres -c "psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -qtAX" <<'SQL'
CREATE EXTENSION pg_stats_backport;
CREATE TABLE t (c text, n int);
CREATE INDEX ON t (n);
SELECT pg_catalog.pg_restore_relation_stats(
  'version','180000'::integer,'schemaname','public','relname','t',
  'relpages','100'::integer,'reltuples','1000'::real,
  'relallvisible','100'::integer,'relallfrozen','0'::integer);
EXPLAIN SELECT c FROM t WHERE n = 5;
SELECT pg_catalog.pg_restore_attribute_stats(
  'version','180000'::integer,'schemaname','public','relname','t','attname','c',
  'inherited','f'::boolean,'null_frac','0'::real,
  'most_common_vals','{red,green,blue}','most_common_freqs','{0.5,0.3,0.2}'::real[]);
SQL

# A bad value: on 13 to 15 this takes the subtransaction fallback, which must
# turn the error into a WARNING and carry on.
su postgres -c "psql -h 127.0.0.1 -U postgres -qtAX -c \"SELECT pg_catalog.pg_restore_attribute_stats(
  'version','180000'::integer,'schemaname','public','relname','t','attname','n',
  'inherited','f'::boolean,
  'most_common_vals','{abc,def}','most_common_freqs','{0.5,0.5}'::real[]);\""

su postgres -c "pg_ctl -D /tmp/pg -m fast -w stop" >/dev/null 2>&1 || true
sleep 2

echo "=== Valgrind reports naming this repo's sources"
if grep -HnE "$OUR_SOURCES" /tmp/vg.*.log; then
  echo "FAIL: Valgrind reported a memory error in this repo's code. Context:"
  grep -HnE -B5 -A20 "$OUR_SOURCES" /tmp/vg.*.log || true
  exit 1
fi
echo "=== memcheck PASSED on PostgreSQL ${PG_MAJOR}"
