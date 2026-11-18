-- Growth bounds on the database itself (dev-reset S6), run by the `reset` job and by CI's reset-roundtrip after a reset:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -v max_audit=<n> -v max_db_mb=<n> -f scripts/dev-bounds.sql
-- Prints the two numbers and fails (division by zero) when either is above its bound.
\set ON_ERROR_STOP on
select count(*) as n_audit from auth.audit_log_entries \gset
select (pg_database_size(current_database()) / 1048576)::bigint as db_mb \gset
\echo auth.audit_log_entries=:n_audit (bound :max_audit)
\echo db_size_mb=:db_mb (bound :max_db_mb)
select 1 / (case when :n_audit <= :max_audit then 1 else 0 end) as audit_log_within_bound;
select 1 / (case when :db_mb <= :max_db_mb then 1 else 0 end) as db_size_within_bound;
