-- Batch A prerequisite: audit actions come from app.audit_action; unknown ones are still refused (23514).
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select is((select count(*)::int from app.audit_action where feature = '02'), 7, 'all seven 02 actions are registered');
select is((select count(*)::int from pg_constraint where conrelid = 'public.audit_event'::regclass and contype = 'c' and conname = 'audit_event_action_check'), 0,
  'the old fixed-list check is gone');
select is((select count(*)::int from pg_constraint where conrelid = 'public.audit_event'::regclass and contype = 'c' and conname = 'audit_event_action_known'), 1,
  'the registry check exists');

select lives_ok($$ insert into public.audit_event (action, source) values ('user.created', 'tap6') $$, 'a 02 action is still accepted');
select throws_ok($$ insert into public.audit_event (action, source) values ('tap_example.created', 'tap6') $$, '23514', null,
  'an unregistered action is refused');
insert into app.audit_action (action, feature) values ('tap_example.created', 'tap6');
select lives_ok($$ insert into public.audit_event (action, source) values ('tap_example.created', 'tap6') $$, 'a newly registered action is accepted');
select throws_ok($$ insert into app.audit_action (action, feature) values ('Bad.Name', 'tap6') $$, '23514', null,
  'registry entries must be lower_snake.lower_snake');

set local role authenticated;
select throws_ok($$ select * from app.audit_action $$, '42501', null, 'authenticated cannot read the registry');
select throws_ok($$ insert into app.audit_action (action, feature) values ('x.y', 'tap6') $$, '42501', null, 'authenticated cannot register actions');
reset role;

select * from finish();
rollback;
