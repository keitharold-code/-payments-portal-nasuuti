-- Two sites, one user per role, books, suppliers, a requisition. Fixed ids so tests read easily.
create table t.ids (k text primary key, id uuid not null);
create function t.id(k text) returns uuid language sql stable as $$ select id from t.ids where k = $1 $$;
grant select on t.ids to authenticated; grant execute on function t.id(text) to authenticated;

insert into auth.users select gen_random_uuid() from generate_series(1,0);
do $$
declare u text; uid uuid; nas uuid; viv uuid;
begin
  foreach u in array array['cashier','mgr','d1','d2','admin','auditor','nobody','viv_cashier','d1b'] loop
    uid := gen_random_uuid(); insert into auth.users values (uid); insert into t.ids values (u, uid);
  end loop;
  select id into nas from core.sites where code = 'NAS';
  insert into core.sites (code, name) values ('VIV', 'Vivo Test') returning id into viv;
  insert into t.ids values ('nas', nas), ('viv', viv);
  insert into core.user_roles (user_id, module, role, site_id) values
    (t.id('cashier'),'payments','cashier',nas), (t.id('mgr'),'payments','station_manager',nas),
    (t.id('d1'),'payments','d1',nas), (t.id('d2'),'payments','d2',nas),
    (t.id('admin'),'payments','admin',nas), (t.id('auditor'),'payments','auditor',nas),
    (t.id('d1b'),'payments','d1',nas),
    (t.id('cashier'),'sales','manager',nas),
    (t.id('viv_cashier'),'payments','cashier',viv);
  insert into core.departments (site_id, name, default_category) values (viv,'Shop','stock_restock');
end $$;

-- files, books, requisition, suppliers (site NAS)
do $$
declare nas uuid := t.id('nas'); cu uuid := t.id('cashier'); f uuid; vb uuid; pb uuid; rb uuid; rq uuid; s1 uuid; s2 uuid; dep uuid;
begin
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by)
    values (nas, 'nas/test/voucher1.jpg', 'voucher', 'image/jpeg', 1000, cu) returning id into f;
  insert into t.ids values ('file1', f);
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, uploaded_by)
    values (nas, 'nas/test/receipt1.jpg', 'receipt', 'image/jpeg', 1000, cu) returning id into f;
  insert into t.ids values ('receipt1', f);

  insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on)
    values (nas, 'shop', 401, 450, '2026-10-01') returning id into vb;
  insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on)
    values (nas, 'petty_cash', 1, 100, '2026-10-01') returning id into pb;
  insert into payments.requisition_books (site_id, type, serial_from, serial_to, issued_on)
    values (nas, 'shop', 1, 100, '2026-10-01') returning id into rb;
  insert into t.ids values ('vbook', vb), ('pbook', pb), ('rbook', rb);

  select id into dep from core.departments where site_id = nas and name = 'Shop';
  insert into t.ids values ('dep_shop', dep);
  insert into payments.requisitions (site_id, book_id, serial_no, department_id) values (nas, rb, 12, dep) returning id into rq;
  insert into t.ids values ('req12', rq);

  insert into payments.suppliers (site_id, name, default_method) values (nas, 'Psalms Food Industry', 'bank_transfer') returning id into s1;
  insert into payments.suppliers (site_id, name) values (nas, 'Kyoga Millers') returning id into s2;
  insert into t.ids values ('psalms', s1), ('kyoga', s2);
end $$;

-- helper: build a payment. Each call gets its own fresh requisition unless o has same_req_as (a voucher no).
create sequence t.reqseq start 20;
create function t.mk_payment(vno int, amt bigint, o jsonb default '{}') returns uuid language plpgsql as $$
declare id uuid := gen_random_uuid(); rq uuid;
begin
  if o ? 'same_req_as' then
    select requisition_id into rq from payments.payments where voucher_no = (o->>'same_req_as')::int;
  else
    insert into payments.requisitions (site_id, book_id, serial_no, department_id)
      values (t.id('nas'), t.id('rbook'), nextval('t.reqseq'), t.id('dep_shop')) returning payments.requisitions.id into rq;
  end if;
  insert into payments.payments (id, site_id, pay_no, requisition_id, voucher_book_id, voucher_no, supplier_id, description,
     amount_ugx, method, payee_details_snapshot, date_required, urgency, category, captured_by, voucher_scan_file_id)
  values (id, t.id('nas'), payments.next_pay_no(t.id('nas')), rq, t.id('vbook'), vno,
     coalesce((o->>'supplier')::uuid, t.id('psalms')), 'Test', amt, coalesce((o->>'method')::payments.pay_method, 'bank_transfer'),
     '{}', current_date, 'normal', 'stock_restock', coalesce((o->>'captured_by')::uuid, t.id('cashier')), t.id('file1'));
  return id;
end $$;
