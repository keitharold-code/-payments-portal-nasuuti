select t.ok((select count(*) from payments.audit_log where table_name = 'payments.suppliers' and action = 'insert') >= 2, 'inserts are audited');
update payments.suppliers set tin = '1001' where id = t.id('kyoga');
select t.ok(exists (select 1 from payments.audit_log where row_id = t.id('kyoga') and action = 'update'
   and old_row->>'tin' is null and new_row->>'tin' = '1001'), 'update logs old and new row');
update payments.suppliers set deleted_at = now() where id = t.id('kyoga');
select t.ok(exists (select 1 from payments.audit_log where row_id = t.id('kyoga') and action = 'soft_delete'), 'soft delete is logged as such');
update payments.suppliers set deleted_at = null where id = t.id('kyoga');
select t.throws($$update payments.audit_log set action = 'insert'$$, 'append-only', 'audit_log cannot be updated');
select t.throws($$delete from payments.audit_log$$, 'append-only', 'audit_log cannot be deleted from');
select t.throws($$truncate payments.audit_log$$, 'append-only', 'audit_log cannot be truncated');
insert into payments.payment_events (site_id, payment_id, to_status, user_id) select t.id('nas'), id, 'captured', t.id('cashier') from payments.payments limit 1;
select t.throws($$update payments.payment_events set comment = 'edited'$$, 'append-only', 'payment_events cannot be updated');
select t.throws($$delete from payments.payment_events$$, 'append-only', 'payment_events cannot be deleted from');
select t.throws($$delete from payments.suppliers$$, 'Hard deletes', 'hard delete is blocked on business tables');
select t.throws($$delete from core.user_roles$$, 'Hard deletes', 'hard delete is blocked on roles');
select t.ok(exists (select 1 from payments.audit_log where table_name = 'core.user_roles'), 'role changes are audited');
select t.ok((select updated_at > created_at from payments.suppliers where id = t.id('kyoga')), 'updated_at moves on update');
