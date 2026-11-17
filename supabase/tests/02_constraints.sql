-- Hard blocks at row level.
select t.ok(t.mk_payment(431, 1585500) is not null, 'a valid payment can be created');
select t.ok((select pay_no from payments.payments where voucher_no = 431) = 'NAS-PAY-000001', 'first pay number is NAS-PAY-000001');

select t.throws($$select t.mk_payment(431, 100)$$, '23505', 'same voucher number cannot be used twice');
select t.throws($$select t.mk_payment(500, 100)$$, 'outside this book', 'voucher number outside book range is refused');
select t.throws($$select t.mk_payment(400, 100)$$, 'outside this book', 'voucher number below book range is refused');
select t.throws($$select t.mk_payment(432, 0)$$, 'check', 'amount must be > 0');
select t.throws($$select t.mk_payment(432, -5)$$, 'check', 'negative amount refused');
-- same requisition + supplier twice
select t.throws($$select t.mk_payment(432, 500, '{"same_req_as":431}')$$, 'payments_req_supplier_live', 'same requisition+supplier cannot be captured twice');
select t.lives($$select t.mk_payment(432, 500, jsonb_build_object('supplier', t.id('kyoga'), 'same_req_as', 431))$$, 'same requisition, different supplier is fine (one requisition, several payments)');

-- rejected/cancelled frees the (requisition, supplier) slot, but its voucher number stays used
update payments.payments set status = 'rejected' where voucher_no = 431;
select t.lives($$select t.mk_payment(433, 1585500, '{"same_req_as":431}')$$, 'after rejection a new capture with a NEW voucher number is allowed');
select t.throws($$select t.mk_payment(431, 1585500, jsonb_build_object('supplier', t.id('kyoga')))$$, '23505', 'a rejected voucher number is never reusable');

-- state-consistency checks
select t.throws($$update payments.payments set status = 'verified' where voucher_no = 433$$, 'verified_has_who', 'verified needs a verifier');
select t.throws($$update payments.payments set status = 'verified', verified_by = t.id('cashier') where voucher_no = 433$$, 'sod_verify', 'SoD: capturer cannot verify');
select t.lives($$update payments.payments set status = 'verified', verified_by = t.id('d1'), verified_at = now() where voucher_no = 433$$, 'D1 can verify');
select t.throws($$update payments.payments set status = 'scheduled' where voucher_no = 433$$, 'scheduled_has_date', 'scheduled needs a date');
select t.lives($$update payments.payments set status = 'scheduled', scheduled_date = current_date, scheduled_by = t.id('cashier') where voucher_no = 433$$, 'schedule with date');
select t.throws($$update payments.payments set status = 'released', released_by = t.id('d1'), released_at = now() where voucher_no = 433$$, 'sod_release', 'SoD: verifier cannot release');
select t.throws($$update payments.payments set status = 'released', released_by = t.id('cashier'), released_at = now() where voucher_no = 433$$, 'sod_release', 'SoD: capturer cannot release');
select t.throws($$update payments.payments set status = 'released' where voucher_no = 433$$, 'released_has_who', 'released needs a releaser');
select t.lives($$update payments.payments set status = 'released', released_by = t.id('d2'), released_at = now() where voucher_no = 433$$, 'D2 can release');
select t.throws($$update payments.payments set status = 'closed' where voucher_no = 433$$, 'closed_has_proof', 'closed needs ref, date paid and receipt');
select t.lives($$update payments.payments set status = 'closed', payment_ref = 'TX123', date_paid = current_date, receipt_file_id = t.id('receipt1') where voucher_no = 433$$, 'close with proof');

-- books
select t.throws($$insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on) values (t.id('nas'),'shop',451,500,'2026-11-01')$$, 'voucher_books_one_active', 'only one active book per type per site');
select t.throws($$insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on, status) values (t.id('nas'),'shop',440,480,'2026-11-01','closed')$$, 'voucher_books_no_overlap', 'book ranges of one type cannot overlap');
select t.lives($$insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on, status) values (t.id('nas'),'shop',451,500,'2026-11-01','closed')$$, 'a closed non-overlapping book is fine');
-- requisitions
select t.throws($$insert into payments.requisitions (site_id, book_id, serial_no, department_id) values (t.id('nas'), t.id('rbook'), 12, t.id('dep_shop'))$$, 'requisitions_book_id_serial_no_key', 'requisition (book, serial) is unique');
select t.throws($$insert into payments.requisitions (site_id, book_id, serial_no, department_id) values (t.id('nas'), t.id('rbook'), 101, t.id('dep_shop'))$$, 'outside this book', 'requisition serial must be inside the book');
select t.throws($$insert into payments.requisition_books (site_id, type, serial_from, serial_to, issued_on) values (t.id('nas'),'shop',1,1000,'2026-10-01')$$, 'check', 'requisition serials are 3 digits');
-- suppliers
select t.throws($$insert into payments.suppliers (site_id, name) values (t.id('nas'), 'psalms  FOOD-industry.')$$, 'suppliers_name_unique', 'supplier name unique ignoring case and punctuation');
select t.lives($$insert into payments.suppliers (site_id, name) values (t.id('viv'), 'Psalms Food Industry')$$, 'same supplier name allowed at another site');
-- cross-site
select t.throws($$select t.mk_payment(440, 100, jsonb_build_object('supplier', (select id from payments.suppliers where site_id = t.id('viv') limit 1)))$$, 'different site', 'payment cannot use another site''s supplier');
