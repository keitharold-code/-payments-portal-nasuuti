-- Acceptance test 8 groundwork: payee detail changes need confirmation by someone else.
select t.ok((select details_changed_at is null from payments.suppliers where id = t.id('psalms')), 'supplier with no payee details needs no confirmation');
-- cashier edits bank details
select set_config('request.jwt.claim.sub', t.id('cashier')::text, false);
update payments.suppliers set bank_name = 'Stanbic', account_name = 'Psalms Food', account_no = '9030001' where id = t.id('psalms');
select set_config('request.jwt.claim.sub', '', false);
select t.ok((select details_changed_at is not null and details_changed_by = t.id('cashier') and details_verified_at is null
   from payments.suppliers where id = t.id('psalms')), 'changing bank details stamps who/when and leaves them unconfirmed');
select t.throws($$update payments.suppliers set details_verified_by = t.id('cashier'), details_verified_at = now() where id = t.id('psalms')$$, 'cannot confirm', 'the editor cannot confirm their own change');
select t.lives($$update payments.suppliers set details_verified_by = t.id('d1'), details_verified_at = now() where id = t.id('psalms')$$, 'D1 can confirm');
select t.ok((select details_verified_at >= details_changed_at from payments.suppliers where id = t.id('psalms')), 'confirmed_at >= changed_at means releasable');
-- change again: becomes unconfirmed again
select pg_sleep(0.01);
update payments.suppliers set account_no = '9030002' where id = t.id('psalms');
select t.ok((select details_verified_at < details_changed_at from payments.suppliers where id = t.id('psalms')), 'a second change makes the old confirmation stale');
select t.throws($$update payments.suppliers set account_no = '1', details_verified_by = t.id('d1'), details_verified_at = now() where id = t.id('psalms')$$, 'same step', 'cannot change and confirm in one step');
select t.throws($$insert into payments.suppliers (site_id, name, bank_name, details_verified_by, details_verified_at) values (t.id('nas'),'Pre Verified','X',t.id('d1'),now())$$, 'cannot be confirmed', 'new supplier cannot arrive pre-confirmed');
update payments.suppliers set name = 'Psalms Food Industry Ltd' where id = t.id('psalms');
select t.ok((select details_verified_at < details_changed_at from payments.suppliers where id = t.id('psalms')), 'renaming does not disturb the change/confirm state');
