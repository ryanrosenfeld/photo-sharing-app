-- End-to-end encrypted face reference photos.
--
-- A user's reference photos are sealed on-device with one random AES-256-GCM key and uploaded to the
-- `face-profiles` bucket as `<uid>/<n>.enc`. This table holds that key wrapped (same ECIES scheme as
-- photo_recipients.wrapped_key) to each authorized public key: the owner's own (recipient_id = owner_id, so a
-- second device can recover it) and one per current friend. The server never sees the key or the photos.
--
-- Additive only: legacy plaintext `<uid>/<n>.jpg` objects stay readable until the owner's app re-encrypts them
-- (it does so on next launch) and are then deleted.

create table if not exists public.face_profile_keys (
  owner_id     uuid        not null references public.profiles(id) on delete cascade,
  recipient_id uuid        not null references public.profiles(id) on delete cascade,
  wrapped_key  text        not null,
  created_at   timestamptz not null default now(),
  primary key (owner_id, recipient_id)
);
create index if not exists face_profile_keys_recipient_idx on public.face_profile_keys (recipient_id);

alter table public.face_profile_keys enable row level security;

create policy "Owners and recipients can read face profile keys"
  on public.face_profile_keys for select
  using (auth.uid() = owner_id or auth.uid() = recipient_id);

-- Only the owner writes, and only for themselves or a current friend.
create policy "Owners can grant face profile keys to friends"
  on public.face_profile_keys for insert
  with check (
    auth.uid() = owner_id
    and (
      recipient_id = owner_id
      or exists (select 1 from public.friendships f where f.user_id = owner_id and f.friend_id = recipient_id)
    )
  );

create policy "Owners can replace face profile keys"
  on public.face_profile_keys for update
  using (auth.uid() = owner_id)
  with check (
    auth.uid() = owner_id
    and (
      recipient_id = owner_id
      or exists (select 1 from public.friendships f where f.user_id = owner_id and f.friend_id = recipient_id)
    )
  );

create policy "Owners can revoke face profile keys"
  on public.face_profile_keys for delete
  using (auth.uid() = owner_id);

-- Unfriending (either side) revokes access immediately, without waiting for the owner's app.
create or replace function public.revoke_face_keys_on_unfriend()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.face_profile_keys
   where (owner_id = old.user_id and recipient_id = old.friend_id)
      or (owner_id = old.friend_id and recipient_id = old.user_id);
  return old;
end;
$$;

drop trigger if exists friendships_revoke_face_keys on public.friendships;
create trigger friendships_revoke_face_keys
  after delete on public.friendships
  for each row execute function public.revoke_face_keys_on_unfriend();
