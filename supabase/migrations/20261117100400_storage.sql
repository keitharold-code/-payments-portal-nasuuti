-- Private bucket for scans and receipts. Access rules (who may upload / read which site's folder)
-- are storage.objects policies in 20261117100700_files_and_capture.sql. Files are only ever
-- opened through short-lived signed URLs.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('payments-files', 'payments-files', false, 1572864,
            array['image/jpeg','image/png','image/webp','application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;
