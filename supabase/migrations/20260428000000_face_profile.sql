-- ============================================================
-- Face Profile
-- Adds opt-in server-side face reference photos.
-- Users who enable this upload 3-5 photos of themselves so
-- friends can auto-enroll their face without manual selection.
-- Embeddings are always generated on-device; only the reference
-- photos live on the server, and only for users who opt in.
-- ============================================================


-- ── 1. profiles: add face_profile_enabled ───────────────────

alter table public.profiles
  add column face_profile_enabled boolean not null default false;


-- ── 2. Storage: face-profiles bucket ────────────────────────
-- Private bucket — not publicly accessible.

insert into storage.buckets (id, name, public)
values ('face-profiles', 'face-profiles', false);


-- ── 3. Storage RLS policies ──────────────────────────────────

-- Owners can upload their own reference photos.
-- Path must start with the user's own UUID folder.
create policy "Users can upload their own face profile photos"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'face-profiles'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Any authenticated user can download face profile photos.
-- Friends need this to auto-enroll; the bucket is private so
-- unauthenticated callers cannot access it.
create policy "Authenticated users can download face profile photos"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'face-profiles');

-- Owners can delete their own reference photos (used when
-- disabling or updating the face profile).
create policy "Users can delete their own face profile photos"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'face-profiles'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
