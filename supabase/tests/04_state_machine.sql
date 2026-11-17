-- The table-level guard blocks any status jump the transitions table does not list.
select t.lives($$select t.mk_payment(445, 100)$$, 'new payment starts captured');
select t.throws($$update payments.payments set status = 'released', released_by = t.id('d2'), released_at = now(), verified_by = t.id('d1'), scheduled_date = current_date where voucher_no = 445$$, 'not allowed', 'captured -> released is blocked');
select t.throws($$update payments.payments set status = 'closed' where voucher_no = 445$$, 'not allowed', 'captured -> closed is blocked');
select t.throws($$update payments.payments set status = 'scheduled', scheduled_date = current_date where voucher_no = 445$$, 'not allowed', 'captured -> scheduled is blocked (must verify first)');
select t.throws($$insert into payments.payments (site_id, pay_no, requisition_id, voucher_book_id, voucher_no, supplier_id, description, amount_ugx, method, payee_details_snapshot, date_required, urgency, category, captured_by, voucher_scan_file_id, status, verified_by, verified_at)
   values (t.id('nas'),'NAS-PAY-999999',t.id('req12'),t.id('vbook'),446,t.id('kyoga'),'x',100,'bank_transfer','{}',current_date,'normal','opex',t.id('cashier'),t.id('file1'),'verified',t.id('d1'),now())$$, 'must start as captured', 'cannot insert straight into verified');
update payments.payments set status = 'verified', verified_by = t.id('d1'), verified_at = now() where voucher_no = 445;
select t.lives($$update payments.payments set status = 'captured', verified_by = null, verified_at = null where voucher_no = 445$$, 'verified -> captured reset is allowed (edit after verification)');
select t.ok((select count(*) from payments.transitions where from_status = 'closed') = 1, 'closed has exactly one exit: admin reopen');
select t.ok(not exists (select 1 from payments.transitions where from_status in ('rejected','cancelled')), 'rejected and cancelled are terminal');
select t.ok(exists (select 1 from payments.transitions where from_status = 'closed' and to_status = 'released' and allowed_role = 'admin'), 'reopen is admin only');
update payments.payments set status = 'rejected' where voucher_no = 445;
select t.throws($$update payments.payments set status = 'captured' where voucher_no = 445$$, 'not allowed', 'rejected -> captured is blocked: new capture required');
