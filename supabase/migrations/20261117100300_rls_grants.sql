-- Row-level security. Browser users can only READ; all writes go through SECURITY DEFINER RPCs
-- (later migrations) or service-role Edge Functions.

create function core.has_site_access(_site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.user_roles r
    where r.user_id = auth.uid() and r.site_id = _site and r.active and r.deleted_at is null) $$;

create function payments.has_role(_role text, _site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.user_roles r
    where r.user_id = auth.uid() and r.module = 'payments' and r.role = _role
      and r.site_id = _site and r.active and r.deleted_at is null) $$;

create function payments.can_read(_site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.user_roles r
    where r.user_id = auth.uid() and r.module = 'payments'
      and r.site_id = _site and r.active and r.deleted_at is null) $$;

grant usage on schema core, payments to authenticated;
grant execute on function core.has_site_access(uuid), payments.has_role(text, uuid), payments.can_read(uuid) to authenticated;

revoke all on all tables in schema core, payments from anon, authenticated;
grant select on all tables in schema core, payments to authenticated;
revoke select on payments.site_counters from authenticated;

alter table core.sites enable row level security;
alter table core.user_roles enable row level security;
alter table core.departments enable row level security;
create policy sites_read on core.sites for select to authenticated
  using (deleted_at is null and core.has_site_access(id));
create policy departments_read on core.departments for select to authenticated
  using (deleted_at is null and core.has_site_access(site_id));
create policy user_roles_read on core.user_roles for select to authenticated
  using (deleted_at is null and (user_id = auth.uid() or payments.has_role('admin', site_id)));

do $$
declare r record;
begin
  for r in select c.table_name t, bool_or(c.column_name = 'deleted_at') has_del
           from information_schema.columns c
           where c.table_schema = 'payments'
             and c.table_name not in ('site_counters','transitions')
           group by c.table_name
  loop
    execute format('alter table payments.%I enable row level security', r.t);
    if r.t in ('audit_log','supplier_merges','import_staging') then
      execute format('create policy read_admin_auditor on payments.%I for select to authenticated using (payments.has_role(''admin'', site_id) or payments.has_role(''auditor'', site_id))', r.t);
    else
      execute format('create policy read_site on payments.%I for select to authenticated using (%spayments.can_read(site_id))',
                     r.t, case when r.has_del then 'deleted_at is null and ' else '' end);
    end if;
  end loop;
end $$;
alter table payments.site_counters enable row level security;   -- no policy: invisible to clients
alter table payments.transitions enable row level security;
create policy read_all on payments.transitions for select to authenticated using (true);
