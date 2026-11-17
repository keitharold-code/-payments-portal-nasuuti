-- Storage policies and register_file.
select t.as_user(t.id('cashier'));
select t.lives($$insert into storage.objects (bucket_id, name, owner, metadata)
   values ('payments-files', t.id('nas') || '/2026/voucher/a1.jpg', t.id('cashier'), '{"size":1000,"mimetype":"image/jpeg"}')$$, 'cashier can upload into own site folder');
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('payments-files', t.id('viv') || '/2026/voucher/x.jpg', '{}')$$, 'row-level security', 'cashier cannot upload into another site folder');
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('payments-files', 'not-a-uuid/x.jpg', '{}')$$, 'row-level security', 'malformed path refused');
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('other-bucket', t.id('nas') || '/x.jpg', '{}')$$, 'row-level security', 'other buckets are not covered by these rules');
select t.as_none();
select t.as_user(t.id('viv_cashier'));
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('payments-files', t.id('nas') || '/2026/voucher/y.jpg', '{}')$$, 'row-level security', 'other-site cashier cannot upload into NAS folder');
select t.ok((select count(*) from storage.objects where bucket_id = 'payments-files') = 0, 'other-site cashier cannot see NAS files');
select t.as_none();
select t.as_user(t.id('auditor'));
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('payments-files', t.id('nas') || '/2026/voucher/z.jpg', '{}')$$, 'row-level security', 'auditor cannot upload');
select t.ok((select count(*) from storage.objects where bucket_id = 'payments-files') = 1, 'auditor can read NAS files');
select t.as_none();
select t.as_user(t.id('d2'));
select t.throws($$insert into storage.objects (bucket_id, name, metadata) values ('payments-files', t.id('nas') || '/2026/voucher/d.jpg', '{}')$$, 'row-level security', 'D2 cannot upload');
select t.as_none();
select t.as_user(t.id('nobody'));
select t.ok((select count(*) from storage.objects where bucket_id = 'payments-files') = 0, 'user with no role sees no files');
select t.as_none();

-- register_file
select t.as_user(t.id('cashier'));
select t.lives($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/a1.jpg', 'voucher', 'abc123')$$, 'cashier registers an uploaded file');
select t.ok((select uploaded_by = t.id('cashier') and size_bytes = 1000 and mime = 'image/jpeg' and sha256 = 'abc123' from payments.files where storage_path like '%/a1.jpg'), 'size and type come from storage, uploader from the session');
select t.lives($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/a1.jpg', 'voucher', 'abc123')$$, 'retrying the same registration is harmless');
select t.ok((select count(*) = 1 from payments.files where storage_path like '%/a1.jpg'), 'retry does not create a second row');
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/missing.jpg', 'voucher')$$, 'Upload not found', 'file that was never uploaded is refused');
select t.throws($$select payments.register_file(t.id('viv'), t.id('nas') || '/2026/voucher/a1.jpg', 'voucher')$$, 'Your role cannot', 'cannot register for a site you do not hold a role at');
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/a1.jpg', 'selfie')$$, 'Unknown file kind', 'unknown kind refused');
select t.as_none();
insert into storage.objects (bucket_id, name, owner, metadata) values
  ('payments-files', t.id('nas') || '/2026/voucher/big.jpg', t.id('cashier'), '{"size":2000000,"mimetype":"image/jpeg"}'),
  ('payments-files', t.id('nas') || '/2026/voucher/page.html', t.id('cashier'), '{"size":900,"mimetype":"text/html"}'),
  ('payments-files', t.id('viv') || '/2026/voucher/other.jpg', t.id('cashier'), '{"size":900,"mimetype":"image/jpeg"}');
select t.as_user(t.id('cashier'));
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/big.jpg', 'voucher')$$, 'under 1.5 MB', 'oversize file refused');
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/page.html', 'voucher')$$, 'photos or PDF', 'non-image type refused');
select t.throws($$select payments.register_file(t.id('nas'), t.id('viv') || '/2026/voucher/other.jpg', 'voucher')$$, 'not in your site', 'path from another site refused');
select t.as_none();
select t.as_user(t.id('admin'));
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/a1.jpg', 'voucher')$$, 'already registered', 'a file registered by someone else cannot be claimed');
select t.as_none();
select t.as_user(t.id('auditor'));
select t.throws($$select payments.register_file(t.id('nas'), t.id('nas') || '/2026/voucher/a1.jpg', 'voucher')$$, 'Your role cannot', 'auditor cannot register files');
select t.as_none();
