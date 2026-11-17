create schema t;
create table t.results (name text, ok boolean);
-- t.ok(condition, name)
create function t.ok(c boolean, n text) returns void language plpgsql as $$
begin insert into t.results values (n, coalesce(c, false)); raise notice '% - %', case when coalesce(c,false) then 'ok' else 'NOT OK' end, n; end $$;
-- t.throws(sql, expected message/sqlstate fragment, name): sql must fail and the error must contain the fragment
create function t.throws(q text, frag text, n text) returns void language plpgsql as $$
declare m text; s text; got boolean := false;
begin
  begin execute q; exception when others then got := true; m := sqlerrm; s := sqlstate; end;
  perform t.ok(got and (m ilike '%' || frag || '%' or s = frag), n || case when got and not (m ilike '%'||frag||'%' or s=frag) then ' [got: '||s||' '||m||']' when not got then ' [no error]' else '' end);
end $$;
-- t.lives(sql, name)
create function t.lives(q text, n text) returns void language plpgsql as $$
declare m text; ok boolean := true;
begin
  begin execute q; exception when others then ok := false; m := sqlerrm; end;
  perform t.ok(ok, n || coalesce(' [error: '||m||']', ''));
end $$;
-- act as an authenticated user (until reset): select t.as_user('uuid') ; select t.as_admin()
create function t.as_user(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u::text, false); execute 'set role authenticated'; end $$;
create function t.as_none() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claim.sub', '', false); end $$;
grant usage on schema t to authenticated, anon;
grant execute on all functions in schema t to authenticated, anon;
grant select on t.results to authenticated;
grant insert on t.results to authenticated, anon;
