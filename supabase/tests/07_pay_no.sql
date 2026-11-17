select t.ok(payments.next_pay_no(t.id('viv')) = 'VIV-PAY-000001', 'numbering is per site and uses the site code');
select t.ok(payments.next_pay_no(t.id('viv')) = 'VIV-PAY-000002', 'sequence increments');
select t.ok((select last_value from payments.site_counters where site_id = t.id('nas')) >= 1, 'NAS counter independent of VIV');
-- no gap on rollback: allocate inside a savepoint, roll back, next number is reused ONLY because nothing was issued
do $$
declare a text; b text;
begin
  begin
    a := payments.next_pay_no(t.id('viv'));
    raise exception 'abort';
  exception when raise_exception then null; end;
  b := payments.next_pay_no(t.id('viv'));
  perform t.ok(a = 'VIV-PAY-000003' and b = 'VIV-PAY-000003', 'a failed capture leaves no gap (number returns with the rolled-back transaction)');
end $$;
select t.throws($$select payments.next_pay_no(gen_random_uuid())$$, 'Unknown site', 'unknown site refused');
select t.as_user(t.id('cashier'));
select t.throws($$select payments.next_pay_no(t.id('nas'))$$, 'permission denied', 'clients cannot burn pay numbers');
select t.as_none();
