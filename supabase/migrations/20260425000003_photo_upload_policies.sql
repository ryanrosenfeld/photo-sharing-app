-- Allow client-side photo upload and recipient insertion.
-- In production the recipient insertion will move to an Edge Function,
-- but for now the sending client handles it directly.

-- ─────────────────────────────────────────────
-- photo_recipients: senders can create recipient rows
-- ─────────────────────────────────────────────
-- Reuses the is_photo_sender() security-definer function from migration 000002.
create policy "Senders can insert photo recipients for their photos"
  on public.photo_recipients for insert
  with check (is_photo_sender(photo_id));

-- ─────────────────────────────────────────────
-- Storage: photos bucket access
-- ─────────────────────────────────────────────
-- Authenticated users can upload to the photos bucket.
create policy "Authenticated users can upload photos"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'photos');

-- Public read so AsyncImage can load photos without auth headers.
create policy "Public read of photos bucket"
  on storage.objects for select
  using (bucket_id = 'photos');

-- Senders can delete their own uploads (owner is set automatically on insert).
create policy "Owners can delete their photos"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'photos' and owner = auth.uid()::text);
