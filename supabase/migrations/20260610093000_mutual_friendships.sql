-- ============================================================
-- Mutual friendships + invite links (SPEC v3)
--
-- Replaces the one-way `links` model. `links` is left in place (deprecated, unused by the app)
-- so this migration stays additive; existing active/paused links are backfilled into friendships.
--
--   invites      single-use, expiring codes behind photoshare://invite/<code>
--   friendships  two directional rows per friendship, one per user, each owned by that user:
--                  (user_id=A, friend_id=B): A's Send toggle (A auto-shares photos of B with B)
--                                            A's Receive toggle (A accepts photos from B)
--
-- Clients never write these tables directly: every change goes through the SECURITY DEFINER RPCs
-- below, so a user can only touch their own toggles and can't forge a friendship.
-- ============================================================

create table public.invites (
  code         text        primary key default replace(gen_random_uuid()::text, '-', ''),
  inviter_id   uuid        not null references public.profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default (now() + interval '14 days'),
  accepted_by  uuid        references public.profiles(id) on delete set null,
  accepted_at  timestamptz
);
create index invites_inviter_idx on public.invites (inviter_id);

create table public.friendships (
  user_id          uuid        not null references public.profiles(id) on delete cascade,
  friend_id        uuid        not null references public.profiles(id) on delete cascade,
  send_enabled     boolean     not null default true,
  receive_enabled  boolean     not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id != friend_id)
);
create index friendships_friend_idx on public.friendships (friend_id);

create trigger friendships_updated_at
  before update on public.friendships
  for each row execute function public.set_updated_at();

alter table public.invites     enable row level security;
alter table public.friendships enable row level security;

-- Inviters can see (and so re-display) their own invites. Everything else goes through RPCs.
create policy "Inviters can see their invites"
  on public.invites for select using (auth.uid() = inviter_id);

-- A user sees both directions of their friendships (they need the friend's Receive toggle to show "paused").
create policy "Users can see their friendships"
  on public.friendships for select using (auth.uid() = user_id or auth.uid() = friend_id);

-- ── helpers ──────────────────────────────────────────────────

-- Free plan: Send may be ON for at most 3 friends (SPEC "Freemium"). Pro is unlimited.
create or replace function public.has_send_slot(p_user uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from profiles where id = p_user and plan = 'pro')
      or (select count(*) from friendships where user_id = p_user and send_enabled) < 3;
$$;

-- True when p_sender may deliver a photo to p_recipient: friends, sender's Send ON, recipient's Receive ON.
create or replace function public.can_share_with(p_sender uuid, p_recipient uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1
    from friendships s
    join friendships r on r.user_id = s.friend_id and r.friend_id = s.user_id
    where s.user_id = p_sender and s.friend_id = p_recipient
      and s.send_enabled and r.receive_enabled
  );
$$;

-- ── RPCs ─────────────────────────────────────────────────────

create or replace function public.create_invite()
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into invites (inviter_id) values (auth.uid()) returning code into v_code;
  return v_code;
end;
$$;

-- What the accept screen needs. state: valid | used | expired | self | already_friends | unknown
create or replace function public.preview_invite(p_code text)
returns table (inviter_id uuid, inviter_name text, state text)
language plpgsql security definer set search_path = public stable as $$
declare i invites%rowtype; v_state text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into i from invites where code = p_code;
  if not found then
    return query select null::uuid, null::text, 'unknown'::text; return;
  end if;
  v_state := case
    when i.inviter_id = auth.uid() then 'self'
    when i.accepted_at is not null then 'used'
    when i.expires_at < now() then 'expired'
    when exists (select 1 from friendships where user_id = auth.uid() and friend_id = i.inviter_id) then 'already_friends'
    else 'valid' end;
  return query select i.inviter_id, p.display_name, v_state from profiles p where p.id = i.inviter_id;
end;
$$;

-- Accepting creates both directions at once. Send defaults ON unless that would exceed a free user's limit.
create or replace function public.accept_invite(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare i invites%rowtype; me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into i from invites where code = p_code for update;
  if not found then raise exception 'invite_unknown'; end if;
  if i.inviter_id = me then raise exception 'invite_self'; end if;
  if i.accepted_at is not null then raise exception 'invite_used'; end if;
  if i.expires_at < now() then raise exception 'invite_expired'; end if;
  if exists (select 1 from friendships where user_id = me and friend_id = i.inviter_id) then
    raise exception 'already_friends';
  end if;

  insert into friendships (user_id, friend_id, send_enabled) values
    (me, i.inviter_id, has_send_slot(me)),
    (i.inviter_id, me, has_send_slot(i.inviter_id));
  update invites set accepted_by = me, accepted_at = now() where code = p_code;
  return i.inviter_id;
end;
$$;

-- Friends with both sides' toggles. my_* are mine; their_* are the friend's.
create or replace function public.list_friends()
returns table (
  friend_id uuid, display_name text, avatar_url text, face_profile_enabled boolean,
  my_send boolean, my_receive boolean, their_send boolean, their_receive boolean, created_at timestamptz
) language sql security definer set search_path = public stable as $$
  select m.friend_id, p.display_name, p.avatar_url, p.face_profile_enabled,
         m.send_enabled, m.receive_enabled, t.send_enabled, t.receive_enabled, m.created_at
  from friendships m
  join friendships t on t.user_id = m.friend_id and t.friend_id = m.user_id
  join profiles p on p.id = m.friend_id
  where m.user_id = auth.uid()
  order by m.created_at desc;
$$;

-- Update my toggles for one friend (null = leave unchanged).
create or replace function public.set_friend_prefs(p_friend uuid, p_send boolean default null, p_receive boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare cur friendships%rowtype;
begin
  select * into cur from friendships where user_id = auth.uid() and friend_id = p_friend for update;
  if not found then raise exception 'not_friends'; end if;
  if p_send is true and not cur.send_enabled and not has_send_slot(auth.uid()) then
    raise exception 'send_limit';
  end if;
  update friendships
     set send_enabled = coalesce(p_send, send_enabled),
         receive_enabled = coalesce(p_receive, receive_enabled)
   where user_id = auth.uid() and friend_id = p_friend;
end;
$$;

-- Unilateral and immediate; previously shared photos stay.
create or replace function public.unfriend(p_friend uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from friendships
   where (user_id = auth.uid() and friend_id = p_friend) or (user_id = p_friend and friend_id = auth.uid());
end;
$$;

revoke all on function public.create_invite(), public.preview_invite(text), public.accept_invite(text),
  public.list_friends(), public.set_friend_prefs(uuid, boolean, boolean), public.unfriend(uuid) from public, anon;
grant execute on function public.create_invite(), public.preview_invite(text), public.accept_invite(text),
  public.list_friends(), public.set_friend_prefs(uuid, boolean, boolean), public.unfriend(uuid) to authenticated;

-- ── Server-side enforcement of Send/Receive ──────────────────
-- Photos can only be delivered between friends, and only when sender Send and recipient Receive are both ON.
drop policy if exists "Senders can insert photo recipients for their photos" on public.photo_recipients;
create policy "Senders can insert photo recipients for their photos"
  on public.photo_recipients for insert
  with check (is_photo_sender(photo_id) and can_share_with(auth.uid(), recipient_id));

-- ── Backfill from the old one-way links ──────────────────────
-- Every active/paused link becomes a friendship; the sender's Send reflects the link status.
insert into public.friendships (user_id, friend_id, send_enabled)
select sender_id, recipient_id, status = 'active' from public.links where status in ('active', 'paused')
on conflict do nothing;
insert into public.friendships (user_id, friend_id, send_enabled)
select recipient_id, sender_id, false from public.links where status in ('active', 'paused')
on conflict do nothing;
