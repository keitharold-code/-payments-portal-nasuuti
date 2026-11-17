-- Supplier RPCs: who may call them, and what they enforce.
select t.as_user(t.id('cashier'));
select t.lives($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', '  Nile Breweries  ', 'phone', ' 0772 ', 'tin', '', 'aliases', jsonb_build_array('NBL', ' ')))$$, 'cashier creates a supplier');
select t.ok((select name = 'Nile Breweries' and phone = '0772' and tin is null and aliases = array['NBL'] from payments.suppliers where name = 'Nile Breweries'), 'values are trimmed, blanks become null, empty aliases dropped');
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', 'nile-BREWERIES!'))$$, 'already exists', 'duplicate name (ignoring case and punctuation) gives a friendly error');
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', '   '))$$, 'name is required', 'blank name refused');
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('viv'), 'name', 'Elsewhere'))$$, 'Your role cannot', 'cashier cannot create at another site');
select t.lives($$select payments.save_supplier(jsonb_build_object('id', (select id from payments.suppliers where name = 'Nile Breweries'), 'phone', '0700'))$$, 'patch updates only the given keys');
select t.ok((select phone = '0700' and aliases = array['NBL'] and name = 'Nile Breweries' from payments.suppliers where name = 'Nile Breweries'), 'untouched fields keep their values');
select t.lives($$select payments.save_supplier(jsonb_build_object('id', (select id from payments.suppliers where name = 'Nile Breweries'), 'bank_name', 'Absa', 'account_name', 'Nile Breweries Ltd', 'account_no', '7001'))$$, 'cashier adds bank details');
select t.ok((select details_changed_at is not null and details_changed_by = t.id('cashier') and details_verified_at is null from payments.suppliers where name = 'Nile Breweries'), 'bank details start unconfirmed');
select t.throws($$select payments.confirm_supplier_details((select id from payments.suppliers where name = 'Nile Breweries'))$$, 'Your role cannot', 'cashier cannot confirm');
select t.as_none();

select t.as_user(t.id('d1'));
select t.throws($$select payments.save_supplier(jsonb_build_object('id', (select id from payments.suppliers where name = 'Nile Breweries'), 'phone', '1'))$$, 'Your role cannot', 'D1 cannot edit suppliers');
select t.lives($$select payments.confirm_supplier_details((select id from payments.suppliers where name = 'Nile Breweries'))$$, 'D1 confirms details');
select t.ok((select details_verified_by = t.id('d1') from payments.suppliers where name = 'Nile Breweries'), 'confirmation records D1');
select t.throws($$select payments.confirm_supplier_details(t.id('kyoga'))$$, 'no bank or mobile money', 'nothing to confirm when no payee details exist');
select t.as_none();

-- admin edits then tries to confirm own change
select t.as_user(t.id('admin'));
select t.lives($$select payments.save_supplier(jsonb_build_object('id', (select id from payments.suppliers where name = 'Nile Breweries'), 'account_no', '7002'))$$, 'admin edits account number');
select t.throws($$select payments.confirm_supplier_details((select id from payments.suppliers where name = 'Nile Breweries'))$$, 'cannot confirm', 'admin cannot confirm their own change');
select t.as_none();
select t.as_user(t.id('d1'));
select t.lives($$select payments.confirm_supplier_details((select id from payments.suppliers where name = 'Nile Breweries'))$$, 'D1 can confirm the admin''s change');
select t.as_none();

-- read-only roles
select t.as_user(t.id('auditor'));
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', 'Aud Ltd'))$$, 'Your role cannot', 'auditor cannot create');
select t.as_none();
select t.as_user(t.id('nobody'));
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', 'Nobody Ltd'))$$, 'Your role cannot', 'user with no role cannot create');
select t.as_none();
select t.throws($$select payments.save_supplier(jsonb_build_object('site_id', t.id('nas'), 'name', 'Anon Ltd'))$$, 'Sign in first', 'no session refused');

-- merge
do $$
declare a uuid; b uuid; p1 uuid; p2 uuid;
begin
  insert into payments.suppliers (site_id, name, aliases) values (t.id('nas'), 'Kyoga Millers Ltd', '{"KM"}') returning id into a;
  insert into payments.suppliers (site_id, name) values (t.id('nas'), 'Other Dup') returning id into b;
  insert into t.ids values ('dupA', a), ('dupB', b);
  p1 := t.mk_payment(447, 1000, jsonb_build_object('supplier', a));
  p2 := t.mk_payment(448, 2000, jsonb_build_object('supplier', a));
end $$;
select t.as_user(t.id('cashier'));
select t.throws($$select payments.merge_suppliers(t.id('dupA'), t.id('kyoga'))$$, 'Your role cannot', 'cashier cannot merge');
select t.as_none();
insert into t.ids select 'viv_sup', id from payments.suppliers where site_id = t.id('viv') limit 1;
select t.as_user(t.id('admin'));
select t.throws($$select payments.merge_suppliers(t.id('dupA'), t.id('dupA'))$$, 'two different', 'cannot merge into itself');
select t.throws($$select payments.merge_suppliers(t.id('dupA'), t.id('viv_sup'))$$, 'different sites', 'cannot merge across sites');
select t.lives($$select payments.merge_suppliers(t.id('dupA'), t.id('kyoga'))$$, 'admin merges duplicate into Kyoga Millers');
select t.as_none();
select t.ok((select count(*) = 2 from payments.payments where supplier_id = t.id('kyoga') and voucher_no in (447,448)), 'payment history re-pointed');
select t.ok((select count(*) = 0 from payments.payments where supplier_id = t.id('dupA')), 'nothing left on the merged supplier');
select t.ok((select deleted_at is not null and merged_into = t.id('kyoga') and not active from payments.suppliers where id = t.id('dupA')), 'merged supplier soft-deleted and linked');
select t.ok((select aliases @> array['KM','Kyoga Millers Ltd'] from payments.suppliers where id = t.id('kyoga')), 'old name and aliases kept as aliases');
select t.ok((select payments_repointed = 2 from payments.supplier_merges where from_supplier_id = t.id('dupA')), 'merge is logged with the count');
-- collision: both suppliers on the same requisition
do $$ begin
  perform t.mk_payment(449, 100, jsonb_build_object('supplier', t.id('dupB')));
  perform t.mk_payment(450, 100, jsonb_build_object('supplier', t.id('kyoga'), 'same_req_as', 449));
end $$;
select t.as_user(t.id('admin'));
select t.throws($$select payments.merge_suppliers(t.id('dupB'), t.id('kyoga'))$$, 'same requisition', 'merge refused when both have a payment on one requisition');
select t.as_none();
