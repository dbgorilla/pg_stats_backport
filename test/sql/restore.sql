-- The two restore functions, called the way pg_dump 18 --statistics-only calls them.
CREATE EXTENSION pg_stats_backport;

CREATE TABLE t (id int PRIMARY KEY, color text, span int4range);

-- Relation statistics, including relallfrozen, which exists only on 18.
SELECT pg_catalog.pg_restore_relation_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't',
    'relpages', '1000'::integer, 'reltuples', '100000'::real,
    'relallvisible', '900'::integer, 'relallfrozen', '800'::integer);
SELECT relpages, reltuples, relallvisible FROM pg_class WHERE oid = 't'::regclass;

-- Index statistics.
SELECT pg_catalog.pg_restore_relation_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't_pkey',
    'relpages', '300'::integer, 'reltuples', '100000'::real);
SELECT relpages, reltuples FROM pg_class WHERE oid = 't_pkey'::regclass;

-- Column statistics: most common values, histogram, correlation.
SELECT pg_catalog.pg_restore_attribute_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't', 'attname', 'color',
    'inherited', 'f'::boolean,
    'null_frac', '0.1'::real, 'avg_width', '5'::integer, 'n_distinct', '3'::real,
    'most_common_vals', '{red,green,blue}'::text,
    'most_common_freqs', '{0.5,0.3,0.2}'::real[]);
SELECT pg_catalog.pg_restore_attribute_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't', 'attname', 'id',
    'inherited', 'f'::boolean,
    'null_frac', '0'::real, 'avg_width', '4'::integer, 'n_distinct', '-1'::real,
    'histogram_bounds', '{1,25000,50000,75000,100000}'::text,
    'correlation', '1'::real);
SELECT attname, null_frac, avg_width, n_distinct, most_common_vals,
       most_common_freqs, histogram_bounds, correlation
FROM pg_stats WHERE tablename = 't' AND attname IN ('id', 'color') ORDER BY attname;

-- Range column statistics. pg_stats shows them only from 17, so read pg_statistic.
SELECT pg_catalog.pg_restore_attribute_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't', 'attname', 'span',
    'inherited', 'f'::boolean,
    'null_frac', '0'::real, 'avg_width', '17'::integer, 'n_distinct', '-1'::real,
    'range_length_histogram', '{1,5,10}'::text,
    'range_empty_frac', '0'::real,
    'range_bounds_histogram', '{"[1,2)","[5,10)","[20,30)"}'::text);
SELECT k.kind, k.numbers, k.vals
FROM pg_statistic s,
     LATERAL (VALUES (s.stakind1, s.stanumbers1, s.stavalues1::text),
                     (s.stakind2, s.stanumbers2, s.stavalues2::text),
                     (s.stakind3, s.stanumbers3, s.stavalues3::text)) k(kind, numbers, vals)
WHERE s.starelid = 't'::regclass AND s.staattnum = 3 AND k.kind <> 0
ORDER BY k.kind;

-- A bad value is skipped with a WARNING; the rest of the call still applies.
SELECT pg_catalog.pg_restore_attribute_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't', 'attname', 'id',
    'inherited', 'f'::boolean,
    'null_frac', '0.25'::real,
    'most_common_vals', '{abc,def}'::text,
    'most_common_freqs', '{0.5,0.5}'::real[]);
SELECT null_frac, most_common_vals FROM pg_stats WHERE tablename = 't' AND attname = 'id';

-- Mismatched value and frequency counts are rejected.
SELECT pg_catalog.pg_restore_attribute_stats(
    'version', '180000'::integer,
    'schemaname', 'public', 'relname', 't', 'attname', 'color',
    'inherited', 'f'::boolean,
    'most_common_vals', '{red,green}'::text,
    'most_common_freqs', '{0.5,0.3,0.2}'::real[]);

-- A non-finite row count is rejected.
SELECT pg_catalog.pg_restore_relation_stats(
    'schemaname', 'public', 'relname', 't', 'reltuples', 'NaN'::real);

-- A missing table is an error.
SELECT pg_catalog.pg_restore_relation_stats(
    'schemaname', 'public', 'relname', 'nope', 'reltuples', '1'::real);

-- A view has no statistics.
CREATE VIEW v AS SELECT 1 AS x;
SELECT pg_catalog.pg_restore_relation_stats(
    'schemaname', 'public', 'relname', 'v', 'reltuples', '1'::real);

DROP VIEW v;

-- Clearing puts a table back to never analyzed.
SELECT pg_catalog.pg_clear_attribute_stats('public', 't', 'color', false);
SELECT count(*) FROM pg_stats WHERE tablename = 't' AND attname = 'color';
SELECT pg_catalog.pg_clear_relation_stats('public', 't');
SELECT relpages, reltuples > 0 AS has_rows, relallvisible FROM pg_class WHERE oid = 't'::regclass;

DROP TABLE t;
DROP EXTENSION pg_stats_backport;
