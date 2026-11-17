-- Who can see what; browser roles cannot write.
select t.as_user(t.id('cashier'));
select t.ok((select count(*) from core.user_roles) = 2, 'cashier sees only own role rows (payments + sales)');
select t.ok((select count(*) from core.sites) = 1, 'cashier sees only the site they hold a role at');
select t.ok((select count(*) from payments.suppliers) = 2, 'cashier can read suppliers of own site');
select t.throws($$select count(*) from payments.site_counters$$, 'permission denied', 'site_counters is not readable by clients');
select t.throws($$insert into payments.suppliers (site_id, name) values (t.id('nas'), 'Hacker Ltd')$$, 'permission denied', 'cashier cannot insert directly');
select t.throws($$update payments.suppliers set name = 'X' where true$$, 'permission denied', 'cashier cannot update directly');
select t.throws($$delete from payments.suppliers$$, 'permission denied', 'cashier cannot delete directly');
select t.throws($$insert into core.user_roles (user_id, module, role, site_id) values (t.id('cashier'),'payments','admin',t.id('nas'))$$, 'permission denied', 'cannot grant self a role');
select t.as_none();

select t.as_user(t.id('admin'));
select t.ok((select count(*) from core.user_roles where site_id = t.id('nas')) = 8, 'admin sees every role row at the site');
select t.ok((select count(*) from payments.audit_log) > 0, 'admin can read audit log');
select t.as_none();

select t.as_user(t.id('auditor'));
select t.ok((select count(*) from payments.suppliers) = 2, 'auditor can read');
select t.ok((select count(*) from payments.audit_log) > 0, 'auditor can read audit log');
select t.throws($$update payments.suppliers set name = 'X'$$, 'permission denied', 'auditor cannot write');
select t.as_none();

select t.as_user(t.id('cashier'));
select t.ok((select count(*) from payments.audit_log) = 0, 'cashier cannot read audit log (filtered by RLS)');
select t.as_none();

select t.as_user(t.id('nobody'));
select t.ok((select count(*) from payments.suppliers) = 0, 'user with no roles sees no suppliers');
select t.ok((select count(*) from core.sites) = 0, 'user with no roles sees no sites');
select t.as_none();

select t.as_user(t.id('viv_cashier'));
select t.ok((select count(*) from payments.suppliers) = 0, 'other-site cashier cannot see NAS suppliers');
select t.ok((select count(*) from core.departments) = 1, 'other-site cashier sees only own site departments');
select t.as_none();

-- deactivated role loses access; soft-deleted rows disappear
update core.user_roles set active = false where user_id = t.id('cashier') and module = 'payments';
select t.as_user(t.id('cashier'));
select t.ok((select count(*) from payments.suppliers) = 0, 'deactivated role: no access');
select t.as_none();
update core.user_roles set active = true where user_id = t.id('cashier') and module = 'payments';
update payments.suppliers set deleted_at = now() where id = t.id('kyoga');
select t.as_user(t.id('cashier'));
select t.ok((select count(*) from payments.suppliers) = 1, 'soft-deleted supplier is hidden');
select t.as_none();
update payments.suppliers set deleted_at = null where id = t.id('kyoga');
