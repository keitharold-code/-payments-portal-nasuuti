-- Voucher numbers belong to exactly one place; acceptance test 5 groundwork.
select t.lives($$select t.mk_payment(441, 100, jsonb_build_object('supplier', t.id('kyoga')))$$, 'payment on 441');
select t.lives($$insert into payments.petty_cash_floats (site_id, float_amount, custodian_user_id) values (t.id('nas'), 500000, t.id('cashier'))$$, 'create float');
select t.lives($$insert into payments.petty_cash_entries (site_id, float_id, voucher_book_id, voucher_no, entry_date, description, amount_ugx, payee_text)
  select t.id('nas'), id, t.id('pbook'), 5, current_date, 'Tea', 5000, 'Shop' from payments.petty_cash_floats$$, 'petty cash entry #5 in petty cash book');
select t.throws($$insert into payments.petty_cash_entries (site_id, float_id, voucher_book_id, voucher_no, entry_date, description, amount_ugx, payee_text)
  select t.id('nas'), id, t.id('pbook'), 5, current_date, 'Dup', 5000, 'Shop' from payments.petty_cash_floats$$, 'petty_cash_entries_voucher_book_id_voucher_no_key', 'petty cash number cannot repeat');
select t.throws($$insert into payments.petty_cash_entries (site_id, float_id, voucher_book_id, voucher_no, entry_date, description, amount_ugx, payee_text)
  select t.id('nas'), id, t.id('vbook'), 442, current_date, 'Wrong book', 5000, 'Shop' from payments.petty_cash_floats$$, 'Petty Cash voucher book', 'petty cash entries need a petty cash book');
select t.throws($$insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by) values (t.id('nas'), t.id('pbook'), 5, 'x', t.id('cashier'))$$, 'already used', 'cannot log a petty-cash-used number as cancelled');
select t.throws($$insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by) values (t.id('nas'), t.id('vbook'), 441, 'x', t.id('cashier'))$$, 'already used', 'cannot log a live payment number as cancelled');
select t.lives($$insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by) values (t.id('nas'), t.id('vbook'), 443, 'Spoilt', t.id('cashier'))$$, 'unused number can be logged as cancelled');
select t.throws($$select t.mk_payment(443, 100, jsonb_build_object('supplier', t.id('kyoga')))$$, 'already used', 'a number logged cancelled cannot be captured later');
-- cancelling a captured payment: payment row -> cancelled, then the log entry is allowed
update payments.payments set status = 'cancelled' where voucher_no = 441;
select t.lives($$insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by) values (t.id('nas'), t.id('vbook'), 441, 'Cancelled before verification', t.id('cashier'))$$, 'cancelled payment + its cancelled-voucher log can coexist');
