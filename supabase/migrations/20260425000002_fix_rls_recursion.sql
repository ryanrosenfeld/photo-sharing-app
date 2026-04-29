-- Fix infinite RLS recursion between photos and photo_recipients.
--
-- The cycle:
--   photos policy "Recipients can see photos shared with them"
--     → queries photo_recipients (triggers its RLS)
--   photo_recipients policy "Senders can see recipients of their photos"
--     → queries photos (triggers its RLS)
--     → back to photos policy → infinite loop
--
-- Fix: use SECURITY DEFINER functions for each cross-table check.
-- These run as the function owner and bypass RLS on the queried table,
-- which breaks the cycle while still enforcing the intended access rules.

-- ─────────────────────────────────────────────
-- 1. Helper functions
-- ─────────────────────────────────────────────

create or replace function public.is_photo_recipient(p_photo_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from photo_recipients
    where photo_id = p_photo_id
      and recipient_id = auth.uid()
  );
$$;

create or replace function public.is_photo_sender(p_photo_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from photos
    where id = p_photo_id
      and sender_id = auth.uid()
  );
$$;

-- ─────────────────────────────────────────────
-- 2. Fix photos policy
-- ─────────────────────────────────────────────

drop policy if exists "Recipients can see photos shared with them" on public.photos;

create policy "Recipients can see photos shared with them"
  on public.photos for select
  using (is_photo_recipient(id));

-- ─────────────────────────────────────────────
-- 3. Fix photo_recipients policies
-- ─────────────────────────────────────────────

drop policy if exists "Senders can see recipients of their photos" on public.photo_recipients;

create policy "Senders can see recipients of their photos"
  on public.photo_recipients for select
  using (is_photo_sender(photo_id));

-- Replace the overly-strict update policy so recipients can also
-- set saved_at (not just viewed_at).
drop policy if exists "Recipients can mark photos as viewed" on public.photo_recipients;

create policy "Recipients can update their own entries"
  on public.photo_recipients for update
  using (auth.uid() = recipient_id)
  with check (auth.uid() = recipient_id);
