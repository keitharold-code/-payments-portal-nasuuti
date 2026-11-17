-- Books RPCs and the usage view.
select t.as_user(t.id('cashier'));
select t.throws($$select payments.register_voucher_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'shop', 'serial_from', 501, 'serial_to', 550))$$, 'Close the current active', 'cannot open a second active book of a type');
select t.lives($$select payments.close_book('voucher', t.id('vbook'))$$, 'cashier closes the shop book');
select t.throws($$select payments.register_voucher_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'shop', 'serial_from', 440, 'serial_to', 500))$$, 'overlap', 'overlapping range gives a friendly error');
select t.lives($$select payments.register_voucher_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'shop', 'serial_from', 501, 'serial_to', 550, 'issued_on', '2026-11-17'))$$, 'cashier registers the next shop book');
select t.lives($$select payments.register_requisition_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'lubes', 'serial_from', 1, 'serial_to', 100))$$, 'cashier registers a requisition book');
select t.throws($$select payments.register_requisition_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'office', 'serial_from', 1, 'serial_to', 1000))$$, 'check', 'requisition serials limited to 3 digits');
select t.throws($$select payments.close_book('voucher', gen_random_uuid())$$, 'Book not found', 'unknown book is reported as not found');
select t.as_none();
select t.as_user(t.id('d2'));
select t.throws($$select payments.register_voucher_book(jsonb_build_object('site_id', t.id('nas'), 'type', 'petty_cash', 'serial_from', 101, 'serial_to', 200))$$, 'Your role cannot', 'D2 cannot register books');
select t.as_none();
select t.as_user(t.id('auditor'));
select t.throws($$select payments.close_book('requisition', t.id('rbook'))$$, 'Your role cannot', 'auditor cannot close books');
select t.as_none();

-- usage view
do $$ declare nb uuid; begin
  select id into nb from payments.voucher_books where serial_from = 501;
  insert into t.ids values ('vbook2', nb);
end $$;
select t.ok((select next_no = 501 and used_count = 0 and highest_used is null from payments.voucher_book_usage where id = t.id('vbook2')), 'empty book: next number is the first serial');
select t.ok((select used_count = 6 from payments.voucher_book_usage where id = t.id('vbook')) is not null, 'usage view works on the old book');
insert into payments.cancelled_vouchers (site_id, voucher_book_id, voucher_no, reason, cancelled_by) values (t.id('nas'), t.id('vbook2'), 503, 'Spoilt', t.id('cashier'));
select t.ok((select next_no = 504 and used_count = 1 and highest_used = 503 from payments.voucher_book_usage where id = t.id('vbook2')), 'a cancelled number counts as used; next is highest + 1');
select t.ok((select count(*) from payments.voucher_book_usage v where v.id = t.id('vbook')) = 1, 'one usage row per book');
select t.as_user(t.id('viv_cashier'));
select t.ok((select count(*) from payments.voucher_book_usage) = 0, 'usage view respects site RLS');
select t.as_none();

-- cancelled vouchers RPC
select t.as_user(t.id('cashier'));
select t.lives($$select payments.log_cancelled_voucher(t.id('vbook2'), 505, 'Torn in book')$$, 'cashier logs a cancelled voucher');
select t.throws($$select payments.log_cancelled_voucher(t.id('vbook2'), 505, 'again')$$, '23505', 'same number cannot be logged twice');
select t.throws($$select payments.log_cancelled_voucher(t.id('vbook2'), 600, 'out of range')$$, 'outside this book', 'out-of-range number refused');
select t.throws($$select payments.log_cancelled_voucher(t.id('vbook2'), 506, '  ')$$, 'Give a reason', 'a reason is required');
select t.ok((select cancelled_by = t.id('cashier') from payments.cancelled_vouchers where voucher_no = 505), 'cancelled_by is the caller, not a client-supplied value');
select t.as_none();
select t.as_user(t.id('auditor'));
select t.throws($$select payments.log_cancelled_voucher(t.id('vbook2'), 507, 'x')$$, 'Your role cannot', 'auditor cannot log cancelled vouchers');
select t.as_none();
