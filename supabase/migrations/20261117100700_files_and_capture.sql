-- File access (storage policies + register_file) and the capture RPC.

-- ---------- helpers ----------
create function payments.kampala_today() returns date language sql stable as $$
  select (now() at time zone 'Africa/Kampala')::date $$;

create function payments.setting_num(_site uuid, _key text, _default numeric) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::numeric from payments.settings where site_id = _site and key = _key), _default) $$;

create function payments.ugx_text(n numeric) returns text language sql immutable as $$
  select 'UGX ' || to_char(n, 'FM999,999,999,999') $$;

-- Path layout: {site_uuid}/{yyyy}/{kind}/{file}. The first folder decides who may touch it.
create function payments.path_site(_name text) returns uuid language sql immutable as $$
  select case when _name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
              then split_part(_name, '/', 1)::uuid end $$;

create function payments.can_upload_path(_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.user_roles r
    where r.user_id = auth.uid() and r.module = 'payments'
      and r.role in ('cashier','station_manager','admin')
      and r.site_id = payments.path_site(_name) and r.active and r.deleted_at is null) $$;

create function payments.can_read_path(_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select payments.path_site(_name) is not null and payments.can_read(payments.path_site(_name)) $$;

grant execute on function payments.path_site(text), payments.can_upload_path(text), payments.can_read_path(text),
  payments.kampala_today() to authenticated;

-- Clients may add files to their site's folder and read (sign URLs for) their site's files.
-- No update/delete policy: a stored scan can never be overwritten or removed from the browser.
create policy payments_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'payments-files' and payments.can_upload_path(name));
create policy payments_files_select on storage.objects for select to authenticated
  using (bucket_id = 'payments-files' and payments.can_read_path(name));

-- After uploading, the browser registers the file. The server checks the object really exists,
-- its size and type, and that the path belongs to the caller's site.
create function payments.register_file(_site uuid, _path text, _kind text, _sha256 text default null)
returns payments.files
language plpgsql security definer set search_path = '' as $$
declare o record; f payments.files; sz bigint; mt text;
begin
  perform payments.require_role(_site, array['cashier','station_manager','admin']);
  if _kind not in ('voucher','requisition','receipt','petty_cash','cancelled_voucher','emergency_approval') then
    raise exception 'Unknown file kind' using errcode = 'check_violation'; end if;
  if payments.path_site(_path) is distinct from _site then
    raise exception 'File is not in your site''s folder' using errcode = 'check_violation'; end if;
  select * into o from storage.objects where bucket_id = 'payments-files' and name = _path;
  if not found then raise exception 'Upload not found. Try again.' using errcode = 'no_data_found'; end if;
  sz := coalesce((o.metadata ->> 'size')::bigint, 0);
  mt := coalesce(o.metadata ->> 'mimetype', '');
  if sz <= 0 or sz > 1572864 then raise exception 'File must be under 1.5 MB' using errcode = 'check_violation'; end if;
  if mt not in ('image/jpeg','image/png','image/webp','application/pdf') then
    raise exception 'Only photos or PDF files are allowed' using errcode = 'check_violation'; end if;

  select * into f from payments.files where storage_path = _path;
  if found then
    if f.uploaded_by <> auth.uid() then raise exception 'File already registered' using errcode = 'unique_violation'; end if;
    return f;                                   -- retry after a dropped connection: same answer
  end if;
  insert into payments.files (site_id, storage_path, kind, mime, size_bytes, sha256, uploaded_by)
  values (_site, _path, _kind, mt, sz, nullif(_sha256, ''), auth.uid()) returning * into f;
  return f;
end $$;

-- ---------- capture ----------
create function payments.capture_payment(p jsonb) returns payments.payments
language plpgsql security definer set search_path = '' as $$
declare
  site uuid := (p->>'site_id')::uuid;
  today date := payments.kampala_today();
  rb payments.requisition_books; rq payments.requisitions; vb payments.voucher_books;
  sup payments.suppliers; dep core.departments; vf payments.files;
  amt bigint := nullif(p->>'amount_ugx', '')::bigint;
  meth payments.pay_method := nullif(p->>'method', '')::payments.pay_method;
  req_no int := nullif(p->>'requisition_serial', '')::int;
  v_no int := nullif(p->>'voucher_no', '')::int;
  need date := nullif(p->>'date_required', '')::date;
  dreq date := nullif(p->>'requisition_date', '')::date;
  descr text := btrim(coalesce(p->>'description', ''));
  any_lim numeric := payments.setting_num(site, 'any_method_limit', 300000);
  ceil_lim numeric := payments.setting_num(site, 'mobile_bank_ceiling', 1000000);
  pc_lim numeric := payments.setting_num(site, 'petty_cash_limit', 300000);
  flags text[] := '{}'; snap jsonb; urg payments.urgency; cat payments.category;
  med numeric; n int; out payments.payments;
begin
  perform payments.require_role(site, array['cashier']);

  if amt is null or amt <= 0 then raise exception 'Enter an amount above zero' using errcode = 'check_violation'; end if;
  if descr = '' then raise exception 'Add a short description' using errcode = 'check_violation'; end if;
  if need is null then raise exception 'Enter the date required' using errcode = 'check_violation'; end if;
  if meth is null then raise exception 'Choose a payment method' using errcode = 'check_violation'; end if;
  if v_no is null then raise exception 'Enter the voucher number' using errcode = 'check_violation'; end if;
  if req_no is null then raise exception 'Enter the requisition number' using errcode = 'check_violation'; end if;

  -- supplier from the list
  select * into sup from payments.suppliers
    where id = nullif(p->>'supplier_id', '')::uuid and site_id = site and deleted_at is null;
  if not found then raise exception 'Choose a supplier from the list' using errcode = 'check_violation'; end if;
  if not sup.active then raise exception 'This supplier is inactive' using errcode = 'check_violation'; end if;

  -- books
  select * into vb from payments.voucher_books
    where id = nullif(p->>'voucher_book_id', '')::uuid and site_id = site and deleted_at is null;
  if not found then raise exception 'Choose a voucher book' using errcode = 'check_violation'; end if;
  if vb.status <> 'active' then raise exception 'This voucher book is closed' using errcode = 'check_violation'; end if;
  select * into rb from payments.requisition_books
    where id = nullif(p->>'requisition_book_id', '')::uuid and site_id = site and deleted_at is null;
  if not found then raise exception 'Choose a requisition book' using errcode = 'check_violation'; end if;
  if rb.status <> 'active' then raise exception 'This requisition book is closed' using errcode = 'check_violation'; end if;

  -- requisition: reuse if this serial is already recorded (one requisition can have several payments)
  select * into rq from payments.requisitions where book_id = rb.id and serial_no = req_no and deleted_at is null;
  if found then
    if p ? 'department_id' and nullif(p->>'department_id','') is not null
       and rq.department_id <> (p->>'department_id')::uuid then
      raise exception 'This requisition is already recorded for a different department' using errcode = 'check_violation'; end if;
    select * into dep from core.departments where id = rq.department_id;
  else
    select * into dep from core.departments
      where id = nullif(p->>'department_id', '')::uuid and site_id = site and deleted_at is null and active;
    if not found then raise exception 'Choose the department' using errcode = 'check_violation'; end if;
    insert into payments.requisitions (site_id, book_id, serial_no, department_id, raised_by_name, approved_by_manager, date_raised, scan_file_id)
    values (site, rb.id, req_no, dep.id, nullif(btrim(p->>'raised_by_name'), ''),
            coalesce((p->>'approved_by_manager')::boolean, false), dreq, nullif(p->>'requisition_scan_file_id','')::uuid)
    returning * into rq;
    if not rq.approved_by_manager then flags := array_append(flags, 'req_not_signed'); end if;
  end if;
  dreq := coalesce(dreq, rq.date_raised);

  -- method limits (limits are Settings, not code)
  if meth = 'petty_cash' and amt > pc_lim then
    raise exception 'Petty cash is limited to %', payments.ugx_text(pc_lim) using errcode = 'check_violation'; end if;
  if meth = 'petty_cash' and dep.name = 'Staff & Wages' then
    raise exception 'Salaries cannot be paid from petty cash' using errcode = 'check_violation'; end if;
  if amt > ceil_lim then
    if meth not in ('bank_transfer','cheque') then
      raise exception 'Above % only bank transfer or cheque', payments.ugx_text(ceil_lim) using errcode = 'check_violation'; end if;
  elsif amt > any_lim then
    if meth not in ('mobile_money','bank_transfer') then
      raise exception 'Above % only mobile money or bank transfer', payments.ugx_text(any_lim) using errcode = 'check_violation'; end if;
  end if;

  -- payee details come from the supplier record and are frozen onto the payment
  if meth = 'bank_transfer' and (sup.bank_name is null or sup.account_no is null) then
    raise exception 'This supplier has no bank details. Add them in Suppliers first.' using errcode = 'check_violation'; end if;
  if meth = 'mobile_money' and sup.momo_number is null then
    raise exception 'This supplier has no mobile money number. Add it in Suppliers first.' using errcode = 'check_violation'; end if;
  snap := jsonb_build_object('supplier_name', sup.name, 'method', meth,
    'bank_name', sup.bank_name, 'account_name', sup.account_name, 'account_no', sup.account_no,
    'momo_number', sup.momo_number, 'momo_name', sup.momo_name, 'details_changed_at', sup.details_changed_at);

  -- scan of the signed voucher is mandatory
  select * into vf from payments.files
    where id = nullif(p->>'voucher_scan_file_id', '')::uuid and site_id = site and kind = 'voucher' and deleted_at is null;
  if not found then raise exception 'Attach a photo of the signed voucher' using errcode = 'check_violation'; end if;

  -- derived fields
  urg := case when need <= today + 1 then 'urgent' else 'normal' end;
  cat := coalesce(dep.default_category, 'opex')::payments.category;

  -- warnings (never block; D1 sees them in amber)
  if exists (select 1 from payments.payments x
      where x.supplier_id = sup.id and x.deleted_at is null and x.status not in ('rejected','cancelled')
        and ((x.amount_ugx = amt and x.captured_at > now() - make_interval(days => payments.setting_num(site,'dup_window_days',7)::int))
          or (abs(x.amount_ugx - amt) <= amt * payments.setting_num(site,'dup_near_pct',5) / 100.0
              and x.captured_at > now() - make_interval(days => payments.setting_num(site,'dup_near_days',3)::int)))) then
    flags := array_append(flags, 'dup_possible'); end if;
  if dreq is not null and dreq < today - payments.setting_num(site, 'req_age_days', 14)::int then
    flags := array_append(flags, 'req_old'); end if;
  select percentile_cont(0.5) within group (order by amount_ugx), count(*) into med, n
    from payments.payments where supplier_id = sup.id and deleted_at is null and status not in ('rejected','cancelled');
  if n >= 3 and amt > med * payments.setting_num(site, 'median_multiple', 3) then flags := array_append(flags, 'amount_3x'); end if;
  if need < today then flags := array_append(flags, 'date_before_capture'); end if;
  if exists (select 1 from payments.payments x where x.voucher_scan_file_id = vf.id)
     or (vf.sha256 is not null and exists (select 1 from payments.payments x join payments.files f2 on f2.id = x.voucher_scan_file_id
                                           where f2.sha256 = vf.sha256 and f2.id <> vf.id)) then
    flags := array_append(flags, 'scan_reused'); end if;

  begin
    insert into payments.payments (site_id, pay_no, requisition_id, voucher_book_id, voucher_no, supplier_id, description,
        amount_ugx, method, payee_details_snapshot, date_required, urgency, category, captured_by,
        voucher_scan_file_id, flags)
    values (site, payments.next_pay_no(site), rq.id, vb.id, v_no, sup.id, descr, amt, meth, snap, need, urg, cat,
        auth.uid(), vf.id, flags)
    returning * into out;
  exception when unique_violation then
    if sqlerrm like '%payments_voucher_book_id_voucher_no_key%' then
      raise exception 'Voucher number % is already used', v_no using errcode = 'unique_violation';
    elsif sqlerrm like '%payments_req_supplier_live%' then
      raise exception 'This requisition already has a payment to this supplier' using errcode = 'unique_violation';
    end if;
    raise;
  end;

  insert into payments.payment_events (site_id, payment_id, from_status, to_status, user_id)
  values (site, out.id, null, 'captured', auth.uid());
  return out;
end $$;

do $$
declare f text;
begin
  foreach f in array array['payments.register_file(uuid,text,text,text)', 'payments.capture_payment(jsonb)',
                           'payments.setting_num(uuid,text,numeric)', 'payments.ugx_text(numeric)']
  loop
    execute format('revoke all on function %s from public, anon', f);
  end loop;
  grant execute on function payments.register_file(uuid,text,text,text), payments.capture_payment(jsonb) to authenticated;
end $$;
