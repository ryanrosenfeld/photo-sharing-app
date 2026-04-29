-- ============================================================
-- PhotoShare — Initial Schema
-- ============================================================
-- Paste this entire file into Supabase Dashboard > SQL Editor
-- and click Run.
-- ============================================================


-- ============================================================
-- TABLES
-- ============================================================

-- profiles
-- One row per user; extends auth.users (which Supabase manages).
-- Created automatically via trigger on new user signup.
create table public.profiles (
  id            uuid        primary key references auth.users(id) on delete cascade,
  display_name  text        not null,
  avatar_url    text,
  plan          text        not null default 'free' check (plan in ('free', 'pro')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- links
-- Directional. A row (sender → recipient) means sender wants to
-- auto-share photos containing recipient's face with recipient.
-- Pending requests live here too (status = 'pending').
create table public.links (
  id            uuid        primary key default gen_random_uuid(),
  sender_id     uuid        not null references public.profiles(id) on delete cascade,
  recipient_id  uuid        not null references public.profiles(id) on delete cascade,
  status        text        not null default 'pending'
                            check (status in ('pending', 'active', 'paused', 'declined')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (sender_id, recipient_id),
  check (sender_id != recipient_id)
);

-- photos
-- One row per captured photo. The actual file lives in Supabase Storage.
create table public.photos (
  id            uuid        primary key default gen_random_uuid(),
  sender_id     uuid        not null references public.profiles(id) on delete cascade,
  storage_path  text        not null,
  taken_at      timestamptz not null,
  location_lat  float8,
  location_lng  float8,
  expires_at    timestamptz not null default (now() + interval '30 days'),
  created_at    timestamptz not null default now()
);

-- photo_recipients
-- Junction: which friends received a given photo.
-- Inserted by Edge Function (service role) after face matching.
create table public.photo_recipients (
  photo_id      uuid        not null references public.photos(id) on delete cascade,
  recipient_id  uuid        not null references public.profiles(id) on delete cascade,
  delivered_at  timestamptz,               -- set when push is sent
  viewed_at     timestamptz,               -- set when recipient opens photo
  created_at    timestamptz not null default now(),
  primary key (photo_id, recipient_id)
);

-- device_tokens
-- APNs tokens for push delivery. A user may have multiple devices.
create table public.device_tokens (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references public.profiles(id) on delete cascade,
  apns_token    text        not null unique,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);


-- ============================================================
-- INDEXES
-- ============================================================

create index links_sender_id_idx        on public.links (sender_id);
create index links_recipient_id_idx     on public.links (recipient_id);
create index links_sender_status_idx    on public.links (sender_id, status);
create index photos_sender_id_idx       on public.photos (sender_id);
create index photos_expires_at_idx      on public.photos (expires_at);  -- for cleanup jobs
create index photo_recip_recipient_idx  on public.photo_recipients (recipient_id);
create index device_tokens_user_id_idx  on public.device_tokens (user_id);


-- ============================================================
-- TRIGGERS
-- ============================================================

-- Auto-update updated_at columns
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger links_updated_at
  before update on public.links
  for each row execute function public.set_updated_at();

create trigger device_tokens_updated_at
  before update on public.device_tokens
  for each row execute function public.set_updated_at();

-- Auto-create a profile row when a new auth user is created.
-- Pulls display_name from OAuth metadata (Google/Apple full name)
-- or falls back to the email prefix.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',  -- set by email sign-up
      new.raw_user_meta_data->>'full_name',      -- Google OAuth
      new.raw_user_meta_data->>'name',           -- Apple OAuth
      split_part(new.email, '@', 1)              -- fallback
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.profiles        enable row level security;
alter table public.links           enable row level security;
alter table public.photos          enable row level security;
alter table public.photo_recipients enable row level security;
alter table public.device_tokens   enable row level security;

-- ----------
-- profiles
-- ----------
-- Anyone can look up a profile (needed for friend search).
create policy "Profiles are publicly readable"
  on public.profiles for select
  using (true);

create policy "Users can insert their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- ----------
-- links
-- ----------
create policy "Users can see links they are part of"
  on public.links for select
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Free tier: max 3 outgoing links (pending + active + paused).
-- Pro users bypass the limit.
create policy "Users can create outgoing link requests"
  on public.links for insert
  with check (
    auth.uid() = sender_id
    and (
      exists (
        select 1 from public.profiles
        where id = auth.uid() and plan = 'pro'
      )
      or (
        select count(*) from public.links
        where sender_id = auth.uid()
          and status in ('pending', 'active', 'paused')
      ) < 3
    )
  );

-- Recipient can accept or decline a pending request.
create policy "Recipients can respond to link requests"
  on public.links for update
  using (auth.uid() = recipient_id and status = 'pending')
  with check (status in ('active', 'declined'));

-- Sender can pause or reactivate their own link.
create policy "Senders can pause or activate their links"
  on public.links for update
  using (auth.uid() = sender_id and status in ('active', 'paused'))
  with check (status in ('active', 'paused'));

create policy "Users can remove links they are part of"
  on public.links for delete
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- ----------
-- photos
-- ----------
create policy "Senders can see their own photos"
  on public.photos for select
  using (auth.uid() = sender_id);

create policy "Recipients can see photos shared with them"
  on public.photos for select
  using (
    exists (
      select 1 from public.photo_recipients
      where photo_id = photos.id and recipient_id = auth.uid()
    )
  );

create policy "Users can upload their own photos"
  on public.photos for insert
  with check (auth.uid() = sender_id);

create policy "Senders can delete their own photos"
  on public.photos for delete
  using (auth.uid() = sender_id);

-- ----------
-- photo_recipients
-- ----------
-- INSERT is service-role only (Edge Function after face match).
-- No client insert policy.

create policy "Recipients can see their own entries"
  on public.photo_recipients for select
  using (auth.uid() = recipient_id);

-- Allow the sender to also see who received their photo.
create policy "Senders can see recipients of their photos"
  on public.photo_recipients for select
  using (
    exists (
      select 1 from public.photos
      where id = photo_id and sender_id = auth.uid()
    )
  );

-- Recipient marks a photo as viewed.
create policy "Recipients can mark photos as viewed"
  on public.photo_recipients for update
  using (auth.uid() = recipient_id)
  with check (viewed_at is not null and delivered_at = delivered_at);

-- ----------
-- device_tokens
-- ----------
create policy "Users can manage their own device tokens"
  on public.device_tokens for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
