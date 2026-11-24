-- chore/explicit-grants D4: the Data API privilege set is exactly the expected one, in both directions.
-- A table/view/function without its grants (a new Supabase project gives none implicitly), or an extra grant such as UPDATE on an
-- append-only table, fails here. Scope: schemas public, app, app_policy; grantees anon, authenticated, service_role, PUBLIC.
-- The query is scripts/privilege-snapshot.sql. When a feature adds an object, add its lines below (additions only), in its own PR.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

create temp table expected_grants (line text primary key);
insert into expected_grants
select l from unnest(string_to_array($snap$
function|app._pa_audit(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.uuid,pg_catalog.jsonb,pg_catalog.jsonb,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app._pa_authorise(pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|app._pa_done(pg_catalog.uuid,pg_catalog.uuid,pg_catalog._text)|service_role|EXECUTE
function|app._pa_name_taken(pg_catalog.text,pg_catalog.uuid)|service_role|EXECUTE
function|app._pa_read_guard(pg_catalog.text)|service_role|EXECUTE
function|app._pa_sa_snapshot(public.platform_admin)|service_role|EXECUTE
function|app._pa_tenant_snapshot(public.tenant)|service_role|EXECUTE
function|app._pa_timezone_ok(pg_catalog.text)|service_role|EXECUTE
function|app._pa_validate_sa(pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app._pa_validate_tenant(pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.bool)|service_role|EXECUTE
function|app._revoke_sessions(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app._ua_audit(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.uuid,pg_catalog.jsonb,pg_catalog.jsonb,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|app._ua_authorise(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app._ua_done(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app._ua_dupcheck(pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.uuid)|service_role|EXECUTE
function|app._ua_fail(pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app._ua_has_other_admin(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app._ua_snapshot(public.membership)|service_role|EXECUTE
function|app._ua_validate(pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.bool)|service_role|EXECUTE
function|app.account_check(pg_catalog.uuid)|service_role|EXECUTE
function|app.account_password_changed(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|app.audit_denied(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|app.current_role()|authenticated|EXECUTE
function|app.current_tenant_id()|authenticated|EXECUTE
function|app.is_known_audit_action(pg_catalog.text)|service_role|EXECUTE
function|app.is_platform_admin()|service_role|EXECUTE
function|app.pa_password_changed(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|app.pa_sa_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_sa_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_sa_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app.pa_sa_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_setup_bad_token()|service_role|EXECUTE
function|app.pa_setup_check()|service_role|EXECUTE
function|app.pa_setup_first(pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_tenant_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_tenant_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_tenant_update(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_ua_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_ua_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.pa_ua_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app.tenant_timezone_valid()|service_role|EXECUTE
function|app.timezone_ok(pg_catalog.text)|service_role|EXECUTE
function|app.timezone_shape_ok(pg_catalog.text)|service_role|EXECUTE
function|app.ua_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.ua_check_update(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.ua_create_user(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.ua_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|app.ua_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app.ua_update_user(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|app_policy.attachment_upload_ok(pg_catalog.text)|authenticated|EXECUTE
function|app_policy.can_see_attachment(pg_catalog.text)|authenticated|EXECUTE
function|public.handover_alerts()|authenticated|EXECUTE
function|public.handover_alerts()|service_role|EXECUTE
function|public.handover_checklist()|authenticated|EXECUTE
function|public.handover_checklist()|service_role|EXECUTE
function|public.ho_acknowledge(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|authenticated|EXECUTE
function|public.ho_acknowledge(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|service_role|EXECUTE
function|public.ho_add_note(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|authenticated|EXECUTE
function|public.ho_add_note(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|service_role|EXECUTE
function|public.ho_declare(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.ho_declare(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.ho_exception(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text,pg_catalog.uuid)|authenticated|EXECUTE
function|public.ho_exception(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text,pg_catalog.uuid)|service_role|EXECUTE
function|public.ho_refuse(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|authenticated|EXECUTE
function|public.ho_refuse(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.text)|service_role|EXECUTE
function|public.ho_set_overdue(pg_catalog.uuid,pg_catalog.int4)|authenticated|EXECUTE
function|public.ho_set_overdue(pg_catalog.uuid,pg_catalog.int4)|service_role|EXECUTE
function|public.iss_ack_escalation(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_ack_escalation(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_attachment_begin(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_attachment_begin(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8,pg_catalog.text)|service_role|EXECUTE
function|public.iss_attachment_commit(pg_catalog.uuid,pg_catalog.uuid)|authenticated|EXECUTE
function|public.iss_attachment_commit(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.iss_category_save(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_category_save(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_category_set_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|authenticated|EXECUTE
function|public.iss_category_set_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.iss_escalate(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_escalate(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_note(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_note(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_reassign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_reassign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_reopen(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_reopen(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_report(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.bool)|authenticated|EXECUTE
function|public.iss_report(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.bool)|service_role|EXECUTE
function|public.iss_resolve(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_resolve(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_set_assignee(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_set_assignee(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.iss_start(pg_catalog.uuid,pg_catalog.uuid)|authenticated|EXECUTE
function|public.iss_start(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.iss_verify(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool,pg_catalog.text)|authenticated|EXECUTE
function|public.iss_verify(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool,pg_catalog.text)|service_role|EXECUTE
function|public.issue_alerts()|authenticated|EXECUTE
function|public.issue_alerts()|service_role|EXECUTE
function|public.issue_detail(pg_catalog.uuid)|authenticated|EXECUTE
function|public.issue_detail(pg_catalog.uuid)|service_role|EXECUTE
function|public.issue_list(pg_catalog.jsonb,pg_catalog.int4)|authenticated|EXECUTE
function|public.issue_list(pg_catalog.jsonb,pg_catalog.int4)|service_role|EXECUTE
function|public.my_shift(pg_catalog.timestamptz)|authenticated|EXECUTE
function|public.my_shift(pg_catalog.timestamptz)|service_role|EXECUTE
function|public.pa_audit(pg_catalog.int4)|authenticated|EXECUTE
function|public.pa_audit(pg_catalog.int4)|service_role|EXECUTE
function|public.pa_super_admins()|authenticated|EXECUTE
function|public.pa_super_admins()|service_role|EXECUTE
function|public.pa_tenant_summaries(pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.int4)|authenticated|EXECUTE
function|public.pa_tenant_summaries(pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.int4)|service_role|EXECUTE
function|public.pa_tenant_unit_admins(pg_catalog.uuid)|authenticated|EXECUTE
function|public.pa_tenant_unit_admins(pg_catalog.uuid)|service_role|EXECUTE
function|public.pm_archive_line(pg_catalog.uuid,pg_catalog.uuid)|authenticated|EXECUTE
function|public.pm_archive_line(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.pm_end_target(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.pm_end_target(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.pm_save_line(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.pm_save_line(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.pm_save_machine(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.pm_save_machine(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.pm_save_product(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|authenticated|EXECUTE
function|public.pm_save_product(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.pm_save_site(pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|authenticated|EXECUTE
function|public.pm_save_site(pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.pm_set_machine_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|authenticated|EXECUTE
function|public.pm_set_machine_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.pm_set_product_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|authenticated|EXECUTE
function|public.pm_set_product_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.pm_set_target(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|authenticated|EXECUTE
function|public.pm_set_target(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|service_role|EXECUTE
function|public.psvc_pa_authorise(pg_catalog.uuid)|service_role|EXECUTE
function|public.psvc_pa_password_changed(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.psvc_pa_sa_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_sa_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_sa_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.psvc_pa_sa_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_setup_bad_token()|service_role|EXECUTE
function|public.psvc_pa_setup_check()|service_role|EXECUTE
function|public.psvc_pa_setup_first(pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_tenant_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_tenant_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_tenant_update(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_ua_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_ua_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.psvc_pa_ua_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.rd_attachment_begin(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8,pg_catalog.text)|authenticated|EXECUTE
function|public.rd_attachment_begin(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8,pg_catalog.text)|service_role|EXECUTE
function|public.rd_attachment_commit(pg_catalog.uuid,pg_catalog.uuid)|authenticated|EXECUTE
function|public.rd_attachment_commit(pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.rd_closing(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.int8,pg_catalog.int4,pg_catalog.int4,pg_catalog.text)|authenticated|EXECUTE
function|public.rd_closing(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.int8,pg_catalog.int4,pg_catalog.int4,pg_catalog.text)|service_role|EXECUTE
function|public.rd_correct(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int8,pg_catalog.uuid,pg_catalog.int4,pg_catalog.int4,pg_catalog.text,pg_catalog.text)|authenticated|EXECUTE
function|public.rd_correct(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int8,pg_catalog.uuid,pg_catalog.int4,pg_catalog.int4,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.rd_end_cavities(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.rd_end_cavities(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.rd_opening(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.uuid,pg_catalog.int8,pg_catalog.text)|authenticated|EXECUTE
function|public.rd_opening(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog.uuid,pg_catalog.int8,pg_catalog.text)|service_role|EXECUTE
function|public.rd_set_cavities(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|authenticated|EXECUTE
function|public.rd_set_cavities(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|service_role|EXECUTE
function|public.rd_set_machine_counter(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8)|authenticated|EXECUTE
function|public.rd_set_machine_counter(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.int8)|service_role|EXECUTE
function|public.reading_detail(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.reading_detail(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.reading_state()|authenticated|EXECUTE
function|public.reading_state()|service_role|EXECUTE
function|public.sh_assign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog._uuid,pg_catalog.date,pg_catalog.date)|authenticated|EXECUTE
function|public.sh_assign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog._uuid,pg_catalog.date,pg_catalog.date)|service_role|EXECUTE
function|public.sh_cover(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog._uuid,pg_catalog.uuid,pg_catalog.text)|authenticated|EXECUTE
function|public.sh_cover(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date,pg_catalog._uuid,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.sh_end_target_override(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.sh_end_target_override(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.sh_save_shift(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|authenticated|EXECUTE
function|public.sh_save_shift(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.sh_set_shift_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|authenticated|EXECUTE
function|public.sh_set_shift_retired(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.sh_set_target_override(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|authenticated|EXECUTE
function|public.sh_set_target_override(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.int4,pg_catalog.date)|service_role|EXECUTE
function|public.sh_unassign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog._uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.sh_unassign(pg_catalog.uuid,pg_catalog.uuid,pg_catalog._uuid,pg_catalog.date)|service_role|EXECUTE
function|public.shift_board(pg_catalog.uuid,pg_catalog.date)|authenticated|EXECUTE
function|public.shift_board(pg_catalog.uuid,pg_catalog.date)|service_role|EXECUTE
function|public.svc_account_password_changed(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.bool)|service_role|EXECUTE
function|public.svc_audit_denied(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.uuid,pg_catalog.text)|service_role|EXECUTE
function|public.svc_ua_check_create(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.svc_ua_check_update(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.svc_ua_create_user(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.svc_ua_reset_password(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid)|service_role|EXECUTE
function|public.svc_ua_set_status(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.svc_ua_update_user(pg_catalog.uuid,pg_catalog.uuid,pg_catalog.uuid,pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.text)|service_role|EXECUTE
function|public.today_board()|authenticated|EXECUTE
function|public.today_board()|service_role|EXECUTE
schema|app_policy|authenticated|USAGE
schema|app|authenticated|USAGE
schema|app|service_role|USAGE
schema|public|PUBLIC|USAGE
schema|public|anon|USAGE
schema|public|authenticated|USAGE
schema|public|service_role|USAGE
table|public.assignment_cover|authenticated|SELECT
table|public.assignment_cover|service_role|INSERT
table|public.assignment_cover|service_role|SELECT
table|public.assignment_version|authenticated|SELECT
table|public.assignment_version|service_role|INSERT
table|public.assignment_version|service_role|SELECT
table|public.attachment|authenticated|SELECT
table|public.attachment|service_role|INSERT
table|public.attachment|service_role|SELECT
table|public.audit_event|authenticated|SELECT
table|public.audit_event|service_role|INSERT
table|public.audit_event|service_role|SELECT
table|public.cavity_version|authenticated|SELECT
table|public.cavity_version|service_role|INSERT
table|public.cavity_version|service_role|SELECT
table|public.handover_declaration|authenticated|SELECT
table|public.handover_declaration|service_role|INSERT
table|public.handover_declaration|service_role|SELECT
table|public.handover_exception|authenticated|SELECT
table|public.handover_exception|service_role|INSERT
table|public.handover_exception|service_role|SELECT
table|public.handover_note|authenticated|SELECT
table|public.handover_note|service_role|INSERT
table|public.handover_note|service_role|SELECT
table|public.handover_session|authenticated|SELECT
table|public.handover_session|service_role|INSERT
table|public.handover_session|service_role|SELECT
table|public.handover_setting|authenticated|SELECT
table|public.handover_setting|service_role|INSERT
table|public.handover_setting|service_role|SELECT
table|public.handover_setting|service_role|UPDATE
table|public.issue_acknowledgement|authenticated|SELECT
table|public.issue_acknowledgement|service_role|INSERT
table|public.issue_acknowledgement|service_role|SELECT
table|public.issue_action|authenticated|SELECT
table|public.issue_action|service_role|INSERT
table|public.issue_action|service_role|SELECT
table|public.issue_category|authenticated|SELECT
table|public.issue_category|service_role|DELETE
table|public.issue_category|service_role|INSERT
table|public.issue_category|service_role|SELECT
table|public.issue_category|service_role|UPDATE
table|public.issue_ownership_history|authenticated|SELECT
table|public.issue_ownership_history|service_role|INSERT
table|public.issue_ownership_history|service_role|SELECT
table|public.line|authenticated|SELECT
table|public.line|service_role|DELETE
table|public.line|service_role|INSERT
table|public.line|service_role|SELECT
table|public.line|service_role|UPDATE
table|public.machine_issue|authenticated|SELECT
table|public.machine_issue|service_role|INSERT
table|public.machine_issue|service_role|SELECT
table|public.machine|authenticated|SELECT
table|public.machine|service_role|DELETE
table|public.machine|service_role|INSERT
table|public.machine|service_role|SELECT
table|public.machine|service_role|UPDATE
table|public.membership|authenticated|SELECT
table|public.membership|service_role|DELETE
table|public.membership|service_role|INSERT
table|public.membership|service_role|MAINTAIN
table|public.membership|service_role|REFERENCES
table|public.membership|service_role|SELECT
table|public.membership|service_role|TRIGGER
table|public.membership|service_role|TRUNCATE
table|public.membership|service_role|UPDATE
table|public.platform_admin|authenticated|SELECT
table|public.platform_admin|service_role|DELETE
table|public.platform_admin|service_role|INSERT
table|public.platform_admin|service_role|SELECT
table|public.platform_admin|service_role|UPDATE
table|public.production_reading|authenticated|SELECT
table|public.production_reading|service_role|INSERT
table|public.production_reading|service_role|SELECT
table|public.production_summary|authenticated|SELECT
table|public.production_summary|service_role|INSERT
table|public.production_summary|service_role|SELECT
table|public.product|authenticated|SELECT
table|public.product|service_role|DELETE
table|public.product|service_role|INSERT
table|public.product|service_role|SELECT
table|public.product|service_role|UPDATE
table|public.shift|authenticated|SELECT
table|public.shift|service_role|DELETE
table|public.shift|service_role|INSERT
table|public.shift|service_role|SELECT
table|public.shift|service_role|UPDATE
table|public.site|authenticated|SELECT
table|public.site|service_role|DELETE
table|public.site|service_role|INSERT
table|public.site|service_role|SELECT
table|public.site|service_role|UPDATE
table|public.target_override_version|authenticated|SELECT
table|public.target_override_version|service_role|INSERT
table|public.target_override_version|service_role|SELECT
table|public.target_version|authenticated|SELECT
table|public.target_version|service_role|INSERT
table|public.target_version|service_role|SELECT
table|public.tenant|authenticated|SELECT
table|public.tenant|service_role|DELETE
table|public.tenant|service_role|INSERT
table|public.tenant|service_role|MAINTAIN
table|public.tenant|service_role|REFERENCES
table|public.tenant|service_role|SELECT
table|public.tenant|service_role|TRIGGER
table|public.tenant|service_role|TRUNCATE
table|public.tenant|service_role|UPDATE
view|public.current_target|authenticated|SELECT
view|public.plant_today|authenticated|SELECT
$snap$, E'\n')) l where l <> '';

create temp table actual_grants as
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
select line from lines;

select is(coalesce((select string_agg(line, E'; ' order by line) from (select line from expected_grants except select line from actual_grants) x), ''), '',
  'every expected privilege is granted (missing grants listed on failure)');
select is(coalesce((select string_agg(line, E'; ' order by line) from (select line from actual_grants except select line from expected_grants) x), ''), '',
  'no privilege beyond the expected set (extra grants listed on failure)');

select * from finish();
rollback;
