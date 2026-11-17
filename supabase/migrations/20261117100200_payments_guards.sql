-- Guards: rules that must hold no matter which code path writes the row.
-- (The transition RPCs in later migrations add role checks on top of these.)

-- ---------- state machine (table-driven; tests and RPCs read the same source) ----------
create table payments.transitions (
  from_status payments.payment_status,          -- null = creation
  to_status payments.payment_status not null,
  allowed_role text not null                    -- d1|d2|cashier|station_manager|admin
);
create unique index transitions_uq on payments.transitions (from_status, to_status, allowed_role) nulls not distinct;
insert into payments.transitions values
  (null,        'captured',  'cashier'),
  ('captured',  'verified',  'd1'),
  ('captured',  'rejected',  'd1'),
  ('captured',  'query',     'd1'),
  ('captured',  'cancelled', 'cashier'),
  ('captured',  'verified',  'station_manager'),   -- emergency only, <= limit, flag set
  ('query',     'captured',  'cashier'),
  ('query',     'rejected',  'd1'),
  ('query',     'cancelled', 'cashier'),
  ('verified',  'scheduled', 'cashier'),
  ('verified',  'on_hold',   'd1'), ('verified','on_hold','d2'),
  ('verified',  'rejected',  'd1'),
  ('scheduled', 'scheduled', 'cashier'),
  ('scheduled', 'released',  'd2'),
  ('scheduled', 'on_hold',   'cashier'), ('scheduled','on_hold','d2'), ('scheduled','on_hold','d1'),
  ('on_hold',   'scheduled', 'd1'), ('on_hold','scheduled','d2'),
  ('on_hold',   'rejected',  'd1'), ('on_hold','rejected','d2'),
  ('released',  'closed',    'cashier'),
  ('closed',    'released',  'admin'),
  ('verified',  'captured',  'cashier'), ('scheduled','captured','cashier'), ('on_hold','captured','cashier');

create function payments.guard_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'captured' and coalesce(current_setting('payments.import_mode', true), '') <> 'on' then
      raise exception 'A new payment must start as captured' using errcode = 'check_violation';
    end if;
  elsif new.status is distinct from old.status then
    if not exists (select 1 from payments.transitions t
                   where t.from_status = old.status and t.to_status = new.status) then
      raise exception 'Status change % -> % is not allowed', old.status, new.status
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger payments_guard_status before insert or update of status on payments.payments
  for each row execute function payments.guard_status();

-- ---------- pay numbers: per-site counter inside the caller's transaction (no gaps, never reused) ----------
create function payments.next_pay_no(_site uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare n bigint; c text;
begin
  select code into c from core.sites where id = _site;
  if c is null then raise exception 'Unknown site' using errcode = 'foreign_key_violation'; end if;
  insert into payments.site_counters (site_id, name, last_value) values (_site, 'pay_no', 1)
  on conflict (site_id, name) do update set last_value = payments.site_counters.last_value + 1
  returning last_value into n;
  return c || '-PAY-' || lpad(n::text, 6, '0');
end $$;
revoke all on function payments.next_pay_no(uuid) from public;

-- ---------- generic: updated_at, created_by default, no hard delete, audit ----------
create function core.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create function core.block_hard_delete() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'Hard deletes are not allowed on %.%. Use soft delete.', tg_table_schema, tg_table_name
  using errcode = 'restrict_violation'; end $$;

create function payments.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare act text; o jsonb; n jsonb;
begin
  n := to_jsonb(new);
  if tg_op = 'INSERT' then act := 'insert'; o := null;
  else
    o := to_jsonb(old);
    if (o - 'updated_at') = (n - 'updated_at') then return new; end if;
    act := case when old.deleted_at is null and new.deleted_at is not null then 'soft_delete' else 'update' end;
  end if;
  insert into payments.audit_log (site_id, table_name, row_id, action, old_row, new_row, user_id)
  values ((n->>'site_id')::uuid, tg_table_schema || '.' || tg_table_name, (n->>'id')::uuid, act, o, n, auth.uid());
  return new;
end $$;

-- append-only logs
create function payments.block_mutation() returns trigger language plpgsql set search_path = '' as $$
begin raise exception '% is append-only', tg_table_name using errcode = 'restrict_violation'; end $$;
create trigger audit_log_immutable before update or delete on payments.audit_log
  for each row execute function payments.block_mutation();
create trigger audit_log_no_truncate before truncate on payments.audit_log
  for each statement execute function payments.block_mutation();
create trigger events_immutable before update or delete on payments.payment_events
  for each row execute function payments.block_mutation();
create trigger events_no_truncate before truncate on payments.payment_events
  for each statement execute function payments.block_mutation();

do $$
declare r record;
begin
  for r in select table_schema s, table_name t from information_schema.columns
           where table_schema in ('core','payments') and column_name = 'updated_at'
  loop
    execute format('create trigger touch_updated_at before update on %I.%I for each row execute function core.touch_updated_at()', r.s, r.t);
  end loop;
  for r in select table_schema s, table_name t from information_schema.columns
           where table_schema in ('core','payments') and column_name = 'created_by'
  loop
    execute format('alter table %I.%I alter column created_by set default auth.uid()', r.s, r.t);
  end loop;
  for r in select table_schema s, table_name t from information_schema.columns
           where table_schema in ('core','payments') and column_name = 'deleted_at'
  loop
    execute format('create trigger no_hard_delete before delete on %I.%I for each row execute function core.block_hard_delete()', r.s, r.t);
    execute format('create trigger audit_row after insert or update on %I.%I for each row execute function payments.audit_row()', r.s, r.t);
  end loop;
end $$;
-- settings has no deleted_at: audit it too, and block its deletion
create trigger audit_row after insert or update on payments.settings
  for each row execute function payments.audit_row();
create trigger no_hard_delete before delete on payments.settings
  for each row execute function core.block_hard_delete();

-- ---------- same-site integrity (multi-site safety) ----------
create function payments.check_same_site() returns trigger language plpgsql set search_path = '' as $$
declare n jsonb := to_jsonb(new); bad boolean := false;
begin
  if tg_table_name = 'payments' then
    bad := exists (select 1 from payments.suppliers x where x.id = new.supplier_id and x.site_id <> new.site_id)
        or exists (select 1 from payments.requisitions x where x.id = new.requisition_id and x.site_id <> new.site_id)
        or exists (select 1 from payments.voucher_books x where x.id = new.voucher_book_id and x.site_id <> new.site_id);
  elsif tg_table_name = 'requisitions' then
    bad := exists (select 1 from payments.requisition_books x where x.id = new.book_id and x.site_id <> new.site_id)
        or exists (select 1 from core.departments x where x.id = new.department_id and x.site_id <> new.site_id);
  elsif tg_table_name = 'petty_cash_entries' then
    bad := exists (select 1 from payments.petty_cash_floats x where x.id = new.float_id and x.site_id <> new.site_id)
        or exists (select 1 from payments.voucher_books x where x.id = new.voucher_book_id and x.site_id <> new.site_id);
  end if;
  if bad then raise exception 'Record belongs to a different site' using errcode = 'check_violation'; end if;
  return new;
end $$;
create trigger same_site before insert or update on payments.payments for each row execute function payments.check_same_site();
create trigger same_site before insert or update on payments.requisitions for each row execute function payments.check_same_site();
create trigger same_site before insert or update on payments.petty_cash_entries for each row execute function payments.check_same_site();

-- ---------- requisition serial within its book ----------
create function payments.check_requisition_serial() returns trigger language plpgsql set search_path = '' as $$
declare b payments.requisition_books;
begin
  select * into b from payments.requisition_books where id = new.book_id;
  if new.serial_no < b.serial_from or new.serial_no > b.serial_to then
    raise exception 'Requisition serial % is outside this book (% to %)', new.serial_no, b.serial_from, b.serial_to
      using errcode = 'check_violation';
  end if;
  if new.serial_no > 999 then raise exception 'Serial must be 3 digits' using errcode = 'check_violation'; end if;
  return new;
end $$;
create trigger req_serial before insert or update of book_id, serial_no on payments.requisitions
  for each row execute function payments.check_requisition_serial();

-- ---------- voucher numbers: in range, and each number belongs to exactly one place ----------
-- A number may be a payment, OR a petty cash entry, OR logged cancelled. The one overlap allowed:
-- a cancelled payment row plus its cancelled_vouchers log entry.
create function payments.check_voucher_number() returns trigger language plpgsql set search_path = '' as $$
declare b payments.voucher_books; clash text;
begin
  select * into b from payments.voucher_books where id = new.voucher_book_id;
  if new.site_id <> b.site_id then
    raise exception 'Voucher book belongs to a different site' using errcode = 'check_violation';
  end if;
  if new.voucher_no < b.serial_from or new.voucher_no > b.serial_to then
    raise exception 'Voucher number % is outside this book (% to %)', new.voucher_no, b.serial_from, b.serial_to
      using errcode = 'check_violation';
  end if;
  if tg_table_name = 'petty_cash_entries' and b.type <> 'petty_cash' then
    raise exception 'Petty cash entries must use a Petty Cash voucher book' using errcode = 'check_violation';
  end if;

  if tg_table_name = 'payments' then
    select 'a petty cash entry' into clash from payments.petty_cash_entries x
      where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null;
    if clash is null then
      select 'a cancelled voucher' into clash from payments.cancelled_vouchers x
        where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null
          and new.status <> 'cancelled';
    end if;
  elsif tg_table_name = 'petty_cash_entries' then
    select 'a payment' into clash from payments.payments x
      where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null;
    if clash is null then
      select 'a cancelled voucher' into clash from payments.cancelled_vouchers x
        where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null;
    end if;
  else -- cancelled_vouchers
    select 'a petty cash entry' into clash from payments.petty_cash_entries x
      where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null;
    if clash is null then
      select 'a payment' into clash from payments.payments x
        where x.voucher_book_id = new.voucher_book_id and x.voucher_no = new.voucher_no and x.deleted_at is null
          and x.status <> 'cancelled';
    end if;
  end if;
  if clash is not null then
    raise exception 'Voucher number % is already used as %', new.voucher_no, clash using errcode = 'unique_violation';
  end if;
  return new;
end $$;
create trigger voucher_check before insert or update of voucher_book_id, voucher_no, status on payments.payments
  for each row execute function payments.check_voucher_number();
create trigger voucher_check before insert or update of voucher_book_id, voucher_no on payments.petty_cash_entries
  for each row execute function payments.check_voucher_number();
create trigger voucher_check before insert or update of voucher_book_id, voucher_no on payments.cancelled_vouchers
  for each row execute function payments.check_voucher_number();

-- ---------- supplier payee details: change tracking and "someone else must confirm" ----------
create function payments.track_supplier_details() returns trigger language plpgsql set search_path = '' as $$
declare changed boolean;
begin
  if tg_op = 'INSERT' then
    changed := (new.bank_name, new.account_name, new.account_no, new.momo_number, new.momo_name)
               is distinct from (null::text, null::text, null::text, null::text, null::text);
    if new.details_verified_by is not null then
      raise exception 'Details cannot be confirmed when the supplier is created' using errcode = 'check_violation';
    end if;
  else
    changed := (new.bank_name, new.account_name, new.account_no, new.momo_number, new.momo_name)
               is distinct from (old.bank_name, old.account_name, old.account_no, old.momo_number, old.momo_name);
  end if;

  if changed then
    if tg_op = 'UPDATE' and (new.details_verified_by, new.details_verified_at)
         is distinct from (old.details_verified_by, old.details_verified_at) then
      raise exception 'Cannot change payee details and confirm them in the same step' using errcode = 'check_violation';
    end if;
    new.details_changed_at := now();
    new.details_changed_by := auth.uid();
  elsif tg_op = 'UPDATE' and (new.details_verified_by, new.details_verified_at)
         is distinct from (old.details_verified_by, old.details_verified_at) then
    if new.details_verified_by is null or new.details_verified_at is null then
      raise exception 'Confirmation needs who and when' using errcode = 'check_violation';
    end if;
    if new.details_verified_by = new.details_changed_by then
      raise exception 'The person who changed the details cannot confirm them' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger supplier_details before insert or update on payments.suppliers
  for each row execute function payments.track_supplier_details();
