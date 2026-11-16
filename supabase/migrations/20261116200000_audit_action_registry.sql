-- Batch A prerequisite (03 + 04): known audit actions live in a registry table instead of a fixed CHECK list,
-- so each feature registers its own actions with plain inserts in its own migration (no shared constraint edits).
-- Unknown actions are still rejected with a CHECK violation (23514), as 02's tests require.
create table app.audit_action (
  action text primary key check (action ~ '^[a-z_]+\.[a-z_]+$'),
  feature text not null,
  created_at timestamptz not null default now()
);
revoke all on app.audit_action from public, anon, authenticated;

insert into app.audit_action (action, feature) values
  ('user.created', '02'), ('user.updated', '02'), ('user.deactivated', '02'), ('user.reactivated', '02'),
  ('user.password_reset', '02'), ('user.password_changed', '02'), ('access.denied', '02');

create function app.is_known_audit_action(p_action text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from app.audit_action a where a.action = p_action) $$;

-- Only the roles that write audit rows need it (security definer writers run as the owner); 02's test 004 requires
-- that no app function except the two RLS helpers is executable by anon/authenticated.
revoke all on function app.is_known_audit_action(text) from public, anon, authenticated;
grant execute on function app.is_known_audit_action(text) to service_role;

alter table public.audit_event drop constraint audit_event_action_check;
alter table public.audit_event add constraint audit_event_action_known check (app.is_known_audit_action(action));
