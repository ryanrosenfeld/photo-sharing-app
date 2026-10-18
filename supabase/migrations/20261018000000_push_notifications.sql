-- ============================================================
-- Push notifications (SPEC "Notifications")
--
--   device_tokens   existing table; gains `environment` (APNs sandbox vs production) and is written only via RPC
--   push_outbox     one row per notification to send. Written by the triggers below, drained by the
--                   `send-push` Edge Function (service role). Clients can't read or write it.
--
-- Events: a photo is delivered to you (photo_recipients insert) and a friend accepted your invite
-- (invites.accepted_at set). Payloads carry names and ids only, never photo content or paths.
-- Additive: no existing table or function is redefined.
-- ============================================================

alter table public.device_tokens
  add column if not exists environment text not null default 'production'
    check (environment in ('sandbox', 'production'));

create table public.push_outbox (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null references public.profiles(id) on delete cascade,
  kind        text        not null check (kind in ('photo', 'friend_accepted')),
  title       text        not null,
  body        text        not null,
  data        jsonb       not null default '{}',   -- routing hints for the app: {"kind": ..., "photo_id"/"friend_id": ...}
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,                        -- set once handed to APNs (or when the user has no devices)
  read_at     timestamptz,                        -- set when the user opens the app; unread photos drive the badge
  attempts    int         not null default 0
);
create index push_outbox_unsent_idx on public.push_outbox (created_at) where sent_at is null;
create index push_outbox_unread_idx on public.push_outbox (user_id) where read_at is null and kind = 'photo';
alter table public.push_outbox enable row level security;   -- no policies: service role only

-- Where the database should call the Edge Function. Empty (the default) = no immediate dispatch; the function
-- can still be invoked on a schedule to drain the outbox. Set with:
--   insert into private.push_config values ('url', 'https://<ref>.supabase.co/functions/v1/send-push'), ('secret', '<PUSH_WEBHOOK_SECRET>');
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table private.push_config (key text primary key, value text not null);

-- ── token registration (RPCs; the table's own policy would let a client claim someone else's token row) ──

create or replace function public.register_device_token(p_token text, p_environment text default 'production')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  -- A token belongs to one device, and a device to whoever signed in last.
  insert into device_tokens (user_id, apns_token, environment)
  values (auth.uid(), p_token, coalesce(p_environment, 'production'))
  on conflict (apns_token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end;
$$;

create or replace function public.unregister_device_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from device_tokens where apns_token = p_token and user_id = auth.uid();
$$;

-- App opened: stop counting delivered photos toward the badge.
create or replace function public.mark_notifications_read()
returns void language sql security definer set search_path = public as $$
  update push_outbox set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

revoke all on function public.register_device_token(text, text), public.unregister_device_token(text),
  public.mark_notifications_read() from public, anon;
grant execute on function public.register_device_token(text, text), public.unregister_device_token(text),
  public.mark_notifications_read() to authenticated;

-- ── dispatch ─────────────────────────────────────────────────

create extension if not exists pg_net with schema extensions;

-- Never lets a push problem break the write that caused it.
create or replace function public.dispatch_push()
returns trigger language plpgsql security definer set search_path = public, private, extensions as $$
declare v_url text; v_secret text;
begin
  select value into v_url from private.push_config where key = 'url';
  select value into v_secret from private.push_config where key = 'secret';
  if v_url is not null then
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', coalesce(v_secret, '')),
      body := jsonb_build_object('outbox_id', new.id));
  end if;
  return new;
exception when others then
  return new;
end;
$$;

create trigger push_outbox_dispatch after insert on public.push_outbox
  for each row execute function public.dispatch_push();

-- ── event: photo delivered ───────────────────────────────────

create or replace function public.enqueue_photo_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sender uuid; v_name text;
begin
  select ph.sender_id, p.display_name into v_sender, v_name
    from photos ph join profiles p on p.id = ph.sender_id where ph.id = new.photo_id;
  insert into push_outbox (user_id, kind, title, body, data)
  values (new.recipient_id, 'photo', 'PhotoShare', coalesce(v_name, 'A friend') || ' shared a photo with you',
          jsonb_build_object('kind', 'photo', 'photo_id', new.photo_id, 'friend_id', v_sender));
  return new;
end;
$$;

create trigger photo_recipients_push after insert on public.photo_recipients
  for each row execute function public.enqueue_photo_push();

-- ── event: friend accepted your invite ───────────────────────

create or replace function public.enqueue_invite_accepted_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if old.accepted_at is null and new.accepted_at is not null and new.accepted_by is not null then
    select display_name into v_name from profiles where id = new.accepted_by;
    insert into push_outbox (user_id, kind, title, body, data)
    values (new.inviter_id, 'friend_accepted', 'PhotoShare', coalesce(v_name, 'Someone') || ' accepted your friend request',
            jsonb_build_object('kind', 'friend_accepted', 'friend_id', new.accepted_by));
  end if;
  return new;
end;
$$;

create trigger invites_accepted_push after update on public.invites
  for each row execute function public.enqueue_invite_accepted_push();
