-- Private bucket for scans and receipts. No storage.objects policies on purpose:
-- uploads and downloads happen only through signed URLs issued by an Edge Function
-- after a role check (built with the capture screen).
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('payments-files', 'payments-files', false, 1572864,
            array['image/jpeg','image/png','image/webp','application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;
