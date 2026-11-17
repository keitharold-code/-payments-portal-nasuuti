-- capture_payment: hard blocks, derived fields, warnings. Includes acceptance tests 3 and 4.
update payments.voucher_books set serial_to = 999 where id = t.id('vbook2');
create sequence t.capseq start 200; create sequence t.vseq start 510;
create function t.cap_args(o jsonb default '{}') returns jsonb language sql security definer as $$
  select jsonb_build_object('site_id', t.id('nas'), 'requisition_book_id', t.id('rbook2'), 'requisition_serial', nextval('t.capseq'),
    'department_id', t.id('dep_shop'), 'approved_by_manager', true, 'voucher_book_id', t.id('vbook2'), 'voucher_no', nextval('t.vseq'),
    'supplier_id', t.id('capsup'), 'description', 'Test goods', 'amount_ugx', 100000, 'method', 'bank_transfer',
    'date_required', to_char(payments.kampala_today() + 7, 'YYYY-MM-DD'), 'voucher_scan_file_id', t.id('vfile')) || $1 $$;
grant execute on function t.cap_args(jsonb) to authenticated; grant usage on sequence t.capseq, t.vseq to authenticated;

do $$
declare nas uuid := t.id('nas'); cu uuid := t.id('cashier'); s uuid; f uuid; rb2 uuid;
begin
  insert into payments.requisition_books (site_id, type, serial_from, serial_to, issued_on) values (nas, 'shop', 200, 999, '2026-11-01') returning id into rb2;
  insert into t.ids values ('rbook2', rb2);
  insert into payments.suppliers (site_id, name, bank_name, account_name, account_no, momo_number, momo_name)
    values (nas, 'Cap Supplies Ltd', 'Absa', 'Cap Supplies', '5551', '0772000111', 'Cap M') returning id into s;
  insert into t.ids values ('capsup', s);
  insert into payments.suppliers (site_id, name) values (nas, 'Plain Cash Vendor') returning id into s;
  insert into t.ids values ('plainsup', s);
  insert into payments.suppliers (site_id, name, active) values (nas, 'Dormant Co', false) returning id into s;
  insert into t.ids values ('dormant', s);
  insert into payments.suppliers (site_id, name, bank_name, account_no) values (nas, 'Fresh Cap A', 'X', '1') returning id into s;
  insert into t.ids values ('supA', s);
  insert into payments.suppliers (site_id, name) values (nas, 'Fresh Cap B') returning id into s;
  insert into t.ids values ('supB', s);
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by, sha256) values (nas, 'n/v/f1.jpg', 'voucher', 'image/jpeg', 100, cu, 'h1') returning id into f;
  insert into t.ids values ('vfile', f);
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by) values (nas, 'n/v/f2.jpg', 'receipt', 'image/jpeg', 100, cu) returning id into f;
  insert into t.ids values ('rfile', f);
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by) values (t.id('viv'), 'v/v/f3.jpg', 'voucher', 'image/jpeg', 100, t.id('viv_cashier')) returning id into f;
  insert into t.ids values ('vivfile', f);
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by, sha256) values (nas, 'n/v/f4.jpg', 'voucher', 'image/jpeg', 100, cu, 'h1') returning id into f;
  insert into t.ids values ('vfile_same_hash', f);
end $$;
create temp table t_last (k text primary key, v jsonb);
grant all on t_last to authenticated;

create function t.cap(o jsonb default '{}', lbl text default null) returns payments.payments language plpgsql as $$
declare r payments.payments; begin r := payments.capture_payment(t.cap_args(o)); if lbl is not null then insert into t_last values (lbl, to_jsonb(r)) on conflict (k) do update set v = excluded.v; end if; return r; end $$;
create function t.urg(d int) returns text language plpgsql as $$ declare r payments.payments; begin
  r := t.cap(jsonb_build_object('date_required', to_char(payments.kampala_today() + d, 'YYYY-MM-DD'))); return r.urgency::text; end $$;
create function t.catof(dep text) returns text language plpgsql as $$ declare r payments.payments; begin
  r := t.cap(jsonb_build_object('department_id', (select id from core.departments where name = dep and site_id = t.id('nas')))); return r.category::text; end $$;
grant execute on function t.cap(jsonb,text), t.urg(int), t.catof(text) to authenticated;

select t.as_user(t.id('cashier'));
-- happy path

select t.lives($$select t.cap('{"amount_ugx":1585500}', 'first')$$, 'cashier captures a UGX 1,585,500 bank payment');
select t.ok((select v->>'pay_no' ~ '^NAS-PAY-[0-9]{6}$' and v->>'status' = 'captured' and v->>'urgency' = 'normal' and v->>'category' = 'stock_restock'
             and (v->>'amount_ugx')::bigint = 1585500 and v->>'captured_by' = t.id('cashier')::text from t_last where k = 'first'),
  'pay number, status captured, normal urgency, category from department, captured_by is the caller');
select t.ok((select v->'payee_details_snapshot'->>'account_no' = '5551' and v->'payee_details_snapshot'->>'bank_name' = 'Absa' from t_last where k = 'first'), 'payee details snapshotted from the supplier');
select t.ok((select count(*) = 1 from payments.payment_events e join t_last l on l.v->>'id' = e.payment_id::text where e.from_status is null and e.to_status = 'captured' and e.user_id = t.id('cashier')), 'a captured event is written');
select t.ok((select flags = '{}' from payments.payments where id = (select (v->>'id')::uuid from t_last where k = 'first')), 'clean capture has no warnings');
-- later supplier change does not alter the snapshot
select t.as_none();
update payments.suppliers set account_no = '9999' where id = t.id('capsup');
select t.as_user(t.id('cashier'));
select t.ok((select payee_details_snapshot->>'account_no' = '5551' from payments.payments where id = (select (v->>'id')::uuid from t_last where k = 'first')), 'snapshot is frozen even after the supplier changes');
-- pay numbers: consecutive, and a refused capture burns none
select t.lives($$select t.cap('{}', 'a')$$, 'second capture');
select t.throws($$select t.cap('{"amount_ugx":0}')$$, 'above zero', 'refused capture');
select t.lives($$select t.cap('{}', 'b')$$, 'third capture');
select t.ok((select (b.v->>'pay_no')::text = 'NAS-PAY-' || lpad((substring(a.v->>'pay_no' from 9)::int + 1)::text, 6, '0') from t_last a, t_last b where a.k = 'a' and b.k = 'b'), 'refused capture leaves no gap in pay numbers');
select t.as_none();

-- who may capture
select t.as_user(t.id('d1'));      select t.throws($$select t.cap()$$, 'Your role cannot', 'D1 cannot capture');
select t.as_user(t.id('d2'));      select t.throws($$select t.cap()$$, 'Your role cannot', 'D2 cannot capture');
select t.as_user(t.id('admin'));   select t.throws($$select t.cap()$$, 'Your role cannot', 'admin cannot capture');
select t.as_user(t.id('mgr'));     select t.throws($$select t.cap()$$, 'Your role cannot', 'station manager cannot capture');
select t.as_user(t.id('auditor')); select t.throws($$select t.cap()$$, 'Your role cannot', 'auditor cannot capture');
select t.as_user(t.id('nobody'));  select t.throws($$select t.cap()$$, 'Your role cannot', 'user without a role cannot capture');
select t.as_user(t.id('viv_cashier')); select t.throws($$select t.cap()$$, 'Your role cannot', 'cashier of another site cannot capture here');
select t.as_none();

select t.as_user(t.id('cashier'));
-- required fields
select t.throws($$select t.cap('{"amount_ugx":-5}')$$, 'above zero', 'negative amount');
select t.throws($$select t.cap('{"description":"  "}')$$, 'short description', 'blank description');
select t.throws($$select t.cap('{"date_required":""}')$$, 'date required', 'missing date required');
select t.throws($$select t.cap('{"method":""}')$$, 'payment method', 'missing method');
select t.throws($$select t.cap('{"supplier_id":""}')$$, 'from the list', 'supplier required');
select t.throws($$select t.cap(jsonb_build_object('supplier_id', gen_random_uuid()))$$, 'from the list', 'unknown supplier');
select t.throws($$select t.cap(jsonb_build_object('supplier_id', t.id('dormant'), 'method', 'cheque'))$$, 'inactive', 'inactive supplier');
select t.throws($$select t.cap('{"voucher_scan_file_id":""}')$$, 'photo of the signed voucher', 'scan required');
select t.throws($$select t.cap(jsonb_build_object('voucher_scan_file_id', t.id('rfile')))$$, 'photo of the signed voucher', 'a receipt cannot stand in for the voucher scan');
select t.throws($$select t.cap(jsonb_build_object('voucher_scan_file_id', t.id('vivfile')))$$, 'photo of the signed voucher', 'another site''s file cannot be used');
-- numbers and books
select t.throws($$select t.cap('{"voucher_no":1000}')$$, 'outside this book', 'voucher number outside the book');
select t.throws($$select t.cap('{"requisition_serial":150}')$$, 'outside this book', 'requisition serial outside the book');
select t.throws($$select t.cap(jsonb_build_object('voucher_book_id', t.id('vbook'), 'voucher_no', 420))$$, 'closed', 'closed voucher book refused');
select t.lives($$select t.cap('{"voucher_no":520,"requisition_serial":280}')$$, 'capture voucher 520 on requisition 280');
select t.throws($$select t.cap('{"voucher_no":520,"requisition_serial":281}')$$, 'already used', 'same voucher number twice');
select t.throws($$select t.cap('{"voucher_no":521,"requisition_serial":280}')$$, 'already has a payment to this supplier', 'same requisition and supplier twice');
select t.lives($$select t.cap(jsonb_build_object('voucher_no', 522, 'requisition_serial', 280, 'supplier_id', t.id('supA'), 'method', 'bank_transfer'))$$, 'same requisition, different supplier: allowed');
select t.ok((select count(*) = 1 from payments.requisitions where book_id = t.id('rbook2') and serial_no = 280), 'the requisition row is reused, not duplicated');
select t.throws($$select t.cap(jsonb_build_object('voucher_no', 523, 'requisition_serial', 280, 'supplier_id', t.id('supB'), 'method', 'cheque', 'department_id', (select id from core.departments where name = 'Utilities' and site_id = t.id('nas'))))$$, 'different department', 'existing requisition cannot be recorded under another department');
select t.as_none();
-- the failed capture must not have left a requisition behind: serial 150 is outside the book
select t.ok(not exists (select 1 from payments.requisitions where serial_no = 150), 'no half-created requisition after a refused capture');
select t.as_user(t.id('cashier'));

-- method limits (acceptance test 3 included)
select t.throws($$select t.cap('{"amount_ugx":1200000,"method":"petty_cash"}')$$, 'Petty cash is limited', 'UGX 1,200,000 by petty cash is refused');
select t.throws($$select t.cap('{"amount_ugx":1200000,"method":"mobile_money"}')$$, 'only bank transfer or cheque', 'UGX 1,200,000 by mobile money refused');
select t.lives($$select t.cap('{"amount_ugx":1200000,"method":"bank_transfer"}')$$, 'UGX 1,200,000 by bank transfer allowed');
select t.lives($$select t.cap(jsonb_build_object('amount_ugx', 1200000, 'method', 'cheque', 'supplier_id', t.id('supB')))$$, 'UGX 1,200,000 by cheque allowed');
select t.lives($$select t.cap('{"amount_ugx":300000,"method":"petty_cash"}')$$, 'UGX 300,000 by petty cash allowed (boundary)');
select t.throws($$select t.cap('{"amount_ugx":300001,"method":"petty_cash"}')$$, 'Petty cash is limited', 'UGX 300,001 by petty cash refused');
select t.throws($$select t.cap(jsonb_build_object('amount_ugx', 300001, 'method', 'cheque', 'supplier_id', t.id('supB')))$$, 'only mobile money or bank', 'UGX 300,001 by cheque refused');
select t.lives($$select t.cap('{"amount_ugx":300001,"method":"mobile_money"}')$$, 'UGX 300,001 by mobile money allowed');
select t.lives($$select t.cap('{"amount_ugx":1000000,"method":"mobile_money"}')$$, 'UGX 1,000,000 by mobile money allowed (boundary)');
select t.throws($$select t.cap('{"amount_ugx":1000001,"method":"mobile_money"}')$$, 'only bank transfer or cheque', 'UGX 1,000,001 by mobile money refused');
select t.throws($$select t.cap(jsonb_build_object('method', 'petty_cash', 'department_id', (select id from core.departments where name = 'Staff & Wages' and site_id = t.id('nas'))))$$, 'Salaries', 'salaries never by petty cash');
select t.lives($$select t.cap(jsonb_build_object('method', 'bank_transfer', 'department_id', (select id from core.departments where name = 'Staff & Wages' and site_id = t.id('nas'))))$$, 'salaries by bank are fine');
-- payee details must exist for the method
select t.throws($$select t.cap(jsonb_build_object('supplier_id', t.id('plainsup'), 'method', 'bank_transfer'))$$, 'no bank details', 'bank payment needs supplier bank details');
select t.throws($$select t.cap(jsonb_build_object('supplier_id', t.id('plainsup'), 'method', 'mobile_money'))$$, 'no mobile money number', 'mobile money needs supplier number');
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('plainsup'), 'method', 'cheque'))$$, 'cheque needs no stored details');
-- limits come from Settings
select t.as_none();
update payments.settings set value = '100000' where site_id = t.id('nas') and key = 'petty_cash_limit';
select t.as_user(t.id('cashier'));
select t.throws($$select t.cap('{"amount_ugx":150000,"method":"petty_cash"}')$$, 'UGX 100,000', 'petty cash limit follows the setting');
select t.as_none();
update payments.settings set value = '300000' where site_id = t.id('nas') and key = 'petty_cash_limit';
select t.as_user(t.id('cashier'));

-- derived urgency

select t.ok(t.urg(0) = 'urgent', 'needed today is urgent');
select t.ok(t.urg(1) = 'urgent', 'needed tomorrow (within 24 hours) is urgent');
select t.ok(t.urg(2) = 'normal', 'needed in 2 days is normal');
-- derived category

select t.ok(t.catof('Fuel/Forecourt') = 'fuel_order', 'forecourt maps to Fuel Order');
select t.ok(t.catof('Lubricants') = 'stock_restock', 'lubricants maps to Stock Restock');
select t.ok(t.catof('Utilities') = 'opex', 'utilities maps to OpEx');

-- warnings. Acceptance test 4: Kyoga Millers 1,532,500 twice within 7 days
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('kyoga'), 'method', 'cheque', 'amount_ugx', 1532500), 'ky1')$$, 'Kyoga Millers first capture');
select t.ok((select not (v->'flags' ? 'dup_possible') from t_last where k = 'ky1'), 'first capture has no duplicate warning');
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('kyoga'), 'method', 'cheque', 'amount_ugx', 1532500), 'ky2')$$, 'Kyoga Millers second capture (not blocked)');
select t.ok((select v->'flags' ? 'dup_possible' from t_last where k = 'ky2'), 'second capture carries the duplicate warning');
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('kyoga'), 'method', 'cheque', 'amount_ugx', 1600000), 'ky3')$$, 'Kyoga Millers within 5% (UGX 1,600,000)');
select t.ok((select v->'flags' ? 'dup_possible' from t_last where k = 'ky3'), 'amount within 5% within 3 days is flagged');
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('kyoga'), 'method', 'cheque', 'amount_ugx', 1900000), 'ky4')$$, 'Kyoga Millers 20% higher');
select t.ok((select not (v->'flags' ? 'dup_possible') from t_last where k = 'ky4'), 'a clearly different amount is not flagged as duplicate');
-- old requisition, late date
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('supB'), 'method', 'cheque', 'requisition_date', to_char(payments.kampala_today() - 30, 'YYYY-MM-DD'), 'date_required', to_char(payments.kampala_today() - 1, 'YYYY-MM-DD')), 'old')$$, 'old requisition with a past date required');
select t.ok((select v->'flags' ?& array['req_old','date_before_capture'] and v->>'urgency' = 'urgent' from t_last where k = 'old'), 'requisition older than 14 days and date before capture are flagged; past date is urgent');
-- unsigned requisition
select t.lives($$select t.cap('{"approved_by_manager":false}', 'unsigned')$$, 'requisition not signed by the manager');
select t.ok((select v->'flags' ? 'req_not_signed' from t_last where k = 'unsigned'), 'flagged for D1');
-- 3x median
do $$ begin perform t.cap(jsonb_build_object('supplier_id', t.id('supA'), 'amount_ugx', 100000)); perform t.cap(jsonb_build_object('supplier_id', t.id('supA'), 'amount_ugx', 120000)); perform t.cap(jsonb_build_object('supplier_id', t.id('supA'), 'amount_ugx', 110000)); end $$;
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('supA'), 'amount_ugx', 900000), 'big')$$, 'large payment to a regular supplier');
select t.ok((select v->'flags' ? 'amount_3x' from t_last where k = 'big'), 'more than 3x the supplier median is flagged');
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('supA'), 'amount_ugx', 200000), 'ok2')$$, 'ordinary payment');
select t.ok((select not (v->'flags' ? 'amount_3x') from t_last where k = 'ok2'), 'normal amounts are not flagged');
-- same scan on two payments (same file, and same file hash)
select t.lives($$select t.cap(jsonb_build_object('supplier_id', t.id('supB'), 'method', 'cheque', 'voucher_scan_file_id', t.id('vfile_same_hash')), 'rh')$$, 'a different file with the same hash');
select t.ok((select v->'flags' ? 'scan_reused' from t_last where k = 'rh'), 'identical scan image reused on another payment is flagged');
select t.as_none();

-- audit and no direct writes
select t.ok((select count(*) > 0 from payments.audit_log where table_name = 'payments.payments' and action = 'insert'), 'captures are in the audit log');
select t.as_user(t.id('cashier'));
select t.throws($$update payments.payments set amount_ugx = 1 where true$$, 'permission denied', 'cashier cannot edit payments directly');
select t.as_none();
