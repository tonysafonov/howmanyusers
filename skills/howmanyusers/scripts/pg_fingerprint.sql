-- pg_fingerprint.sql: a text fingerprint of a database, to diff before and after a Postgres major upgrade
-- (pg_rehearse.sh runs it on both sides) or before and after a risky migration. Same data -> identical output.
--
--   psql -q -U <user> -d <db> -v migration=alembic -v md5_tables=users,orders -f pg_fingerprint.sql > fp.txt
--
-- Variables (all optional):
--   migration   alembic | drizzle | none       which migration bookkeeping table to print (default none)
--   md5_tables  comma-separated public tables  md5 of every row of each (ordered by the row's text), for the tables
--                                              where silent corruption would hurt most; counts alone miss it
-- Prints: migration version, row count of every public table, sequence positions, constraints per type, index
-- count, invalid indexes, enums, extensions, and the md5 lines.
\if :{?migration} \else \set migration none \endif
\if :{?md5_tables} \else \set md5_tables '' \endif
\pset format unaligned
\pset tuples_only on

SELECT :'migration' = 'alembic' AS is_alembic, :'migration' = 'drizzle' AS is_drizzle \gset
\if :is_alembic
SELECT 'alembic ' || version_num FROM alembic_version;
\endif
\if :is_drizzle
SELECT 'drizzle ' || count(*) || ' ' || coalesce(max(created_at)::text, '-') FROM drizzle.__drizzle_migrations;
\endif

SELECT 'rows ' || rpad(table_name, 32) || (xpath('/row/c/text()',
       query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;
SELECT 'seq ' || rpad(sequencename, 40) || coalesce(last_value::text, 'unused') FROM pg_sequences
WHERE schemaname = 'public' ORDER BY sequencename;
SELECT 'constraints ' || contype::text || ' ' || count(*) FROM pg_constraint c
JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' GROUP BY contype ORDER BY contype;
SELECT 'indexes ' || count(*) FROM pg_indexes WHERE schemaname = 'public';
SELECT 'invalid_indexes ' || count(*) FROM pg_index WHERE NOT indisvalid;
SELECT 'enum ' || t.typname || ' ' || string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid GROUP BY t.typname ORDER BY t.typname;
SELECT 'extensions ' || string_agg(extname, ',' ORDER BY extname) FROM pg_extension;
SELECT 'md5 ' || rpad(t, 32) || (xpath('/row/c/text()', query_to_xml(
       format('SELECT coalesce(md5(string_agg(x::text, ''|'' ORDER BY x::text)), ''empty'') AS c FROM public.%I x', t),
       false, true, '')))[1]::text
FROM unnest(string_to_array(:'md5_tables', ',')) AS t WHERE t <> '' ORDER BY t;
