/* pg_stats_backport--1.0.sql */

\echo Use "CREATE EXTENSION pg_stats_backport" to load this file. \quit

/*
 * PostgreSQL 18 has the four statistics functions built in, and on 18 the
 * library does not contain them, so create nothing. Before 18, create them in
 * pg_catalog with the same signatures as 18, so the schema-qualified calls in
 * pg_dump --statistics-only output resolve to them.
 */
DO $do$
BEGIN
    IF current_setting('server_version_num')::int >= 180000 THEN
        RETURN;
    END IF;

    EXECUTE $ddl$
        CREATE FUNCTION pg_catalog.pg_restore_relation_stats(VARIADIC kwargs "any")
        RETURNS boolean
        LANGUAGE c VOLATILE
        AS 'MODULE_PATHNAME', 'pg_restore_relation_stats'
    $ddl$;

    EXECUTE $ddl$
        CREATE FUNCTION pg_catalog.pg_restore_attribute_stats(VARIADIC kwargs "any")
        RETURNS boolean
        LANGUAGE c VOLATILE
        AS 'MODULE_PATHNAME', 'pg_restore_attribute_stats'
    $ddl$;

    EXECUTE $ddl$
        CREATE FUNCTION pg_catalog.pg_clear_relation_stats(schemaname text, relname text)
        RETURNS void
        LANGUAGE c VOLATILE
        AS 'MODULE_PATHNAME', 'pg_clear_relation_stats'
    $ddl$;

    EXECUTE $ddl$
        CREATE FUNCTION pg_catalog.pg_clear_attribute_stats(
            schemaname text, relname text, attname text, inherited boolean)
        RETURNS void
        LANGUAGE c VOLATILE
        AS 'MODULE_PATHNAME', 'pg_clear_attribute_stats'
    $ddl$;
END
$do$;
