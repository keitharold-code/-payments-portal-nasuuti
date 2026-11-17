-- RPCs for suppliers and books. SECURITY DEFINER: the browser can only read tables, so every
-- write passes through a role check here. The row-level guards (previous migrations) still apply.

create function payments.require_role(_site uuid, _roles text[]) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = 'insufficient_privilege'; end if;
  if not exists (select 1 from core.user_roles r
      where r.user_id = auth.uid() and r.module = 'payments' and r.role = any(_roles)
        and r.site_id = _site and r.active and r.deleted_at is null) then
    raise exception 'Your role cannot do this' using errcode = 'insufficient_privilege';
  end if;
end $$;

-- ---------------- suppliers ----------------
-- Create (no id) or patch (id + only the keys to change). Cashier and Admin.
create function payments.save_supplier(p jsonb) returns payments.suppliers
language plpgsql security definer set search_path = '' as $$
declare s payments.suppliers; sid uuid := nullif(p->>'id','')::uuid; site uuid; nm text;
begin
  if sid is null then
    site := (p->>'site_id')::uuid;
    perform payments.require_role(site, array['cashier','admin']);
    nm := btrim(coalesce(p->>'name',''));
    if nm = '' then raise exception 'Supplier name is required' using errcode = 'check_violation'; end if;
    insert into payments.suppliers (site_id, name, aliases, default_method, bank_name, account_name, account_no,
                                    momo_number, momo_name, tin, phone)
    values (site, nm,
            coalesce(array(select btrim(x) from jsonb_array_elements_text(coalesce(p->'aliases','[]'::jsonb)) x where btrim(x) <> ''), '{}'),
            nullif(p->>'default_method','')::payments.pay_method,
            nullif(btrim(p->>'bank_name'),''), nullif(btrim(p->>'account_name'),''), nullif(btrim(p->>'account_no'),''),
            nullif(btrim(p->>'momo_number'),''), nullif(btrim(p->>'momo_name'),''),
            nullif(btrim(p->>'tin'),''), nullif(btrim(p->>'phone'),''))
    returning * into s;
  else
    select site_id into site from payments.suppliers where id = sid and deleted_at is null;
    if site is null then raise exception 'Supplier not found' using errcode = 'no_data_found'; end if;
    perform payments.require_role(site, array['cashier','admin']);
    if p ? 'name' and btrim(coalesce(p->>'name','')) = '' then
      raise exception 'Supplier name is required' using errcode = 'check_violation'; end if;
    update payments.suppliers u set
      name           = case when p ? 'name'           then btrim(p->>'name') else u.name end,
      aliases        = case when p ? 'aliases'        then coalesce(array(select btrim(x) from jsonb_array_elements_text(p->'aliases') x where btrim(x) <> ''), '{}') else u.aliases end,
      default_method = case when p ? 'default_method' then nullif(p->>'default_method','')::payments.pay_method else u.default_method end,
      bank_name      = case when p ? 'bank_name'      then nullif(btrim(p->>'bank_name'),'')    else u.bank_name end,
      account_name   = case when p ? 'account_name'   then nullif(btrim(p->>'account_name'),'') else u.account_name end,
      account_no     = case when p ? 'account_no'     then nullif(btrim(p->>'account_no'),'')   else u.account_no end,
      momo_number    = case when p ? 'momo_number'    then nullif(btrim(p->>'momo_number'),'')  else u.momo_number end,
      momo_name      = case when p ? 'momo_name'      then nullif(btrim(p->>'momo_name'),'')    else u.momo_name end,
      tin            = case when p ? 'tin'            then nullif(btrim(p->>'tin'),'')          else u.tin end,
      phone          = case when p ? 'phone'          then nullif(btrim(p->>'phone'),'')        else u.phone end,
      active         = case when p ? 'active'         then (p->>'active')::boolean              else u.active end
    where u.id = sid returning * into s;
  end if;
  return s;
exception when unique_violation then
  if sqlerrm like '%suppliers_name_unique%' then
    raise exception 'A supplier with this name already exists' using errcode = 'unique_violation';
  end if;
  raise;
end $$;

-- D1 (or Admin) confirms the current bank / mobile money details. Database trigger refuses
-- the person who made the last change.
create function payments.confirm_supplier_details(_id uuid) returns payments.suppliers
language plpgsql security definer set search_path = '' as $$
declare s payments.suppliers;
begin
  select * into s from payments.suppliers where id = _id and deleted_at is null;
  if not found then raise exception 'Supplier not found' using errcode = 'no_data_found'; end if;
  perform payments.require_role(s.site_id, array['d1','admin']);
  if s.details_changed_at is null then
    raise exception 'This supplier has no bank or mobile money details to confirm' using errcode = 'check_violation'; end if;
  update payments.suppliers set details_verified_by = auth.uid(), details_verified_at = now()
    where id = _id returning * into s;
  return s;
end $$;

-- Admin only. Re-points history from one supplier to another, keeps the old name as an alias.
create function payments.merge_suppliers(_from uuid, _into uuid) returns payments.suppliers
language plpgsql security definer set search_path = '' as $$
declare f payments.suppliers; i payments.suppliers; n_pay int; n_pc int;
begin
  if _from = _into then raise exception 'Choose two different suppliers' using errcode = 'check_violation'; end if;
  select * into f from payments.suppliers where id = _from and deleted_at is null;
  select * into i from payments.suppliers where id = _into and deleted_at is null;
  if f.id is null or i.id is null then raise exception 'Supplier not found' using errcode = 'no_data_found'; end if;
  if f.site_id <> i.site_id then raise exception 'Suppliers belong to different sites' using errcode = 'check_violation'; end if;
  perform payments.require_role(f.site_id, array['admin']);

  if exists (select 1 from payments.payments a join payments.payments b on a.requisition_id = b.requisition_id
             where a.supplier_id = _from and b.supplier_id = _into and a.deleted_at is null and b.deleted_at is null
               and a.status not in ('rejected','cancelled') and b.status not in ('rejected','cancelled')) then
    raise exception 'Both suppliers have a payment on the same requisition; resolve that first' using errcode = 'unique_violation';
  end if;

  update payments.payments set supplier_id = _into where supplier_id = _from;
  get diagnostics n_pay = row_count;
  update payments.petty_cash_entries set supplier_id = _into where supplier_id = _from;
  get diagnostics n_pc = row_count;

  update payments.suppliers set
    aliases = (select coalesce(array_agg(distinct a), '{}') from unnest(i.aliases || f.aliases || f.name) a)
    where id = _into returning * into i;
  update payments.suppliers set active = false, merged_into = _into, deleted_at = now(), deleted_by = auth.uid()
    where id = _from;
  insert into payments.supplier_merges (site_id, from_supplier_id, into_supplier_id, payments_repointed, merged_by)
    values (f.site_id, _from, _into, n_pay + n_pc, auth.uid());
  return i;
end $$;

-- ---------------- books ----------------
create function payments.register_voucher_book(p jsonb) returns payments.voucher_books
language plpgsql security definer set search_path = '' as $$
declare site uuid := (p->>'site_id')::uuid; b payments.voucher_books; ty payments.voucher_book_type := (p->>'type')::payments.voucher_book_type;
begin
  perform payments.require_role(site, array['cashier','admin']);
  if exists (select 1 from payments.voucher_books where site_id = site and type = ty and status = 'active' and deleted_at is null) then
    raise exception 'Close the current active % book first', ty using errcode = 'unique_violation'; end if;
  insert into payments.voucher_books (site_id, type, serial_from, serial_to, issued_on)
  values (site, ty, (p->>'serial_from')::int, (p->>'serial_to')::int, coalesce((p->>'issued_on')::date, current_date))
  returning * into b;
  return b;
exception when exclusion_violation then
  raise exception 'These numbers overlap another % voucher book', ty using errcode = 'exclusion_violation';
end $$;

create function payments.register_requisition_book(p jsonb) returns payments.requisition_books
language plpgsql security definer set search_path = '' as $$
declare site uuid := (p->>'site_id')::uuid; b payments.requisition_books;
begin
  perform payments.require_role(site, array['cashier','admin']);
  insert into payments.requisition_books (site_id, type, serial_from, serial_to, issued_on)
  values (site, (p->>'type')::payments.req_book_type, (p->>'serial_from')::int, (p->>'serial_to')::int,
          coalesce((p->>'issued_on')::date, current_date))
  returning * into b;
  return b;
end $$;

create function payments.close_book(_kind text, _id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare site uuid;
begin
  if _kind = 'voucher' then
    select site_id into site from payments.voucher_books where id = _id and deleted_at is null;
  elsif _kind = 'requisition' then
    select site_id into site from payments.requisition_books where id = _id and deleted_at is null;
  else raise exception 'Unknown book kind' using errcode = 'check_violation';
  end if;
  if site is null then raise exception 'Book not found' using errcode = 'no_data_found'; end if;
  perform payments.require_role(site, array['cashier','admin']);
  if _kind = 'voucher' then update payments.voucher_books set status = 'closed' where id = _id;
  else update payments.requisition_books set status = 'closed' where id = _id; end if;
end $$;

-- A voucher number that was spoilt or voided, so it stops showing as "missing".
create function payments.log_cancelled_voucher(_book uuid, _no int, _reason text, _scan uuid default null)
returns payments.cancelled_vouchers
language plpgsql security definer set search_path = '' as $$
declare b payments.voucher_books; c payments.cancelled_vouchers;
begin
  select * into b from payments.voucher_books where id = _book and deleted_at is null;
  if b.id is null then raise exception 'Book not found' using errcode = 'no_data_found'; end if;
  perform payments.require_role(b.site_id, array['cashier','admin']);
  if btrim(coalesce(_reason,'')) = '' then raise exception 'Give a reason' using errcode = 'check_violation'; end if;
  insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by, scan_file_id)
  values (b.site_id, _book, _no, btrim(_reason), auth.uid(), _scan) returning * into c;
  return c;
end $$;

-- Book usage for the Books screen and for pre-filling the next voucher number at capture.
-- distinct: a cancelled payment appears as a payment row AND a cancelled log entry
create view payments.voucher_book_usage with (security_invoker = true) as
select b.id, b.site_id, b.type, b.serial_from, b.serial_to, b.issued_on, b.status,
       count(distinct u.no) as used_count,
       max(u.no) as highest_used,
       case when coalesce(max(u.no), b.serial_from - 1) + 1 > b.serial_to then null
            else coalesce(max(u.no), b.serial_from - 1) + 1 end as next_no
from payments.voucher_books b
left join lateral (
  select voucher_no as no from payments.payments p where p.voucher_book_id = b.id and p.deleted_at is null
  union all select voucher_no from payments.petty_cash_entries e where e.voucher_book_id = b.id and e.deleted_at is null
  union all select voucher_no from payments.cancelled_vouchers c where c.voucher_book_id = b.id and c.deleted_at is null
) u on true
where b.deleted_at is null
group by b.id;
grant select on payments.voucher_book_usage to authenticated;

-- ---------------- grants: only signed-in users may call the RPCs ----------------
do $$
declare f text;
begin
  foreach f in array array[
    'payments.require_role(uuid,text[])','payments.save_supplier(jsonb)','payments.confirm_supplier_details(uuid)',
    'payments.merge_suppliers(uuid,uuid)','payments.register_voucher_book(jsonb)','payments.register_requisition_book(jsonb)',
    'payments.close_book(text,uuid)','payments.log_cancelled_voucher(uuid,int,text,uuid)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
