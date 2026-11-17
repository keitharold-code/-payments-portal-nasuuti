-- Fix: payments.audit_row() read old.deleted_at, which tables without that column (settings) do not have.
-- Reads soft-delete state from the row's JSON instead.
create or replace function payments.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare act text; o jsonb; n jsonb;
begin
  n := to_jsonb(new);
  if tg_op = 'INSERT' then act := 'insert'; o := null;
  else
    o := to_jsonb(old);
    if (o - 'updated_at') = (n - 'updated_at') then return new; end if;
    act := case when o->>'deleted_at' is null and n->>'deleted_at' is not null then 'soft_delete' else 'update' end;
  end if;
  insert into payments.audit_log (site_id, table_name, row_id, action, old_row, new_row, user_id)
  values ((n->>'site_id')::uuid, tg_table_schema || '.' || tg_table_name, (n->>'id')::uuid, act, o, n, auth.uid());
  return new;
end $$;
