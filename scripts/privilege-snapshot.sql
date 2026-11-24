-- Data API privilege snapshot (chore/explicit-grants D2/D4). Prints one stable line per privilege:
--   kind|object|grantee|privilege
-- Scope: schemas public, app, app_policy (the only non-system schemas our migrations create);
-- grantees anon, authenticated, service_role and PUBLIC; extension-owned objects excluded.
-- NULL ACLs are expanded with acldefault() so "never granted" and "default" are explicit.
-- Same query as supabase/tests/070_privilege_contract.test.sql. Usage:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -qAt -f scripts/privilege-snapshot.sql
with grantees(oid, name) as (
  select 0::oid, 'PUBLIC'
  union all select oid, rolname::text from pg_roles where rolname in ('anon', 'authenticated', 'service_role')
), scope as (
  select oid, nspname::text as nspname from pg_namespace where nspname in ('public', 'app', 'app_policy')
), lines as (
  select 'schema|' || s.nspname || '|' || g.name || '|' || a.privilege_type as line
  from pg_namespace n
  join scope s on s.oid = n.oid
  cross join lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  join grantees g on g.oid = a.grantee
  union all
  select case c.relkind when 'S' then 'sequence' when 'v' then 'view' when 'm' then 'matview'
                        when 'f' then 'foreign' else 'table' end
         || '|' || s.nspname || '.' || c.relname || '|' || g.name || '|' || a.privilege_type
  from pg_class c
  join scope s on s.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault((case when c.relkind = 'S' then 's' else 'r' end)::"char", c.relowner))) a
  join grantees g on g.oid = a.grantee
  where c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
  union all
  select 'column|' || s.nspname || '.' || c.relname || '.' || t.attname || '|' || g.name || '|' || a.privilege_type
  from pg_attribute t
  join pg_class c on c.oid = t.attrelid
  join scope s on s.oid = c.relnamespace
  cross join lateral aclexplode(t.attacl) a
  join grantees g on g.oid = a.grantee
  where t.attacl is not null and not t.attisdropped
  union all
  select 'function|' || s.nspname || '.' || p.proname || '('
         || coalesce((select string_agg(tn.nspname || '.' || ty.typname, ',' order by u.ord)
                      from unnest(p.proargtypes::oid[]) with ordinality u(o, ord)
                      join pg_type ty on ty.oid = u.o
                      join pg_namespace tn on tn.oid = ty.typnamespace), '')
         || ')|' || g.name || '|' || a.privilege_type
  from pg_proc p
  join scope s on s.oid = p.pronamespace
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  join grantees g on g.oid = a.grantee
  where not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
)
select line from lines order by line collate "C";
