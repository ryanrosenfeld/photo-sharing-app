-- PhotoShare Seed Data
-- Run this in the Supabase SQL editor (Dashboard → SQL Editor).
-- It creates 3 test accounts and seeds links + photos between them.
--
-- Test credentials (all passwords: Test1234!)
--   alice@test.com  ← sign in as this user to see received photos
--   sarah@test.com
--   marcus@test.com
--
-- After seeding, go to Storage → create a public bucket named "photos".
-- Upload any placeholder images to seed/photo_1.jpg … seed/photo_8.jpg,
-- or leave it empty — the UI will show a grey placeholder for missing images.

-- ─────────────────────────────────────────────
-- 0. Ensure pgcrypto is available
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─────────────────────────────────────────────
-- 1. Auth users  (bypass FK / RLS for seeding)
-- ─────────────────────────────────────────────
SET session_replication_role = 'replica';

INSERT INTO auth.users (
  instance_id, id, aud, role,
  email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token,
  email_change_token_new, email_change
)
VALUES
  (
    '00000000-0000-0000-0000-000000000000',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'authenticated', 'authenticated',
    'alice@test.com',
    crypt('Test1234!', gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Alice Park"}',
    now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'authenticated', 'authenticated',
    'sarah@test.com',
    crypt('Test1234!', gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Sarah Chen"}',
    now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'authenticated', 'authenticated',
    'marcus@test.com',
    crypt('Test1234!', gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"display_name":"Marcus Johnson"}',
    now(), now(), '', '', '', ''
  )
ON CONFLICT (id) DO NOTHING;

SET session_replication_role = 'origin';

-- ─────────────────────────────────────────────
-- 2. Profiles  (trigger may already create these;
--    ON CONFLICT DO UPDATE ensures display_name is set)
-- ─────────────────────────────────────────────
INSERT INTO profiles (id, display_name, plan)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Alice Park',      'free'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Sarah Chen',      'free'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Marcus Johnson',  'pro')
ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;

-- ─────────────────────────────────────────────
-- 3. Links
--   sarah  → alice  (active)   sarah sends photos to alice
--   marcus → alice  (active)   marcus sends photos to alice
--   alice  → sarah  (active)   alice sends photos to sarah
--   marcus → sarah  (pending)  pending request sarah hasn't answered
-- ─────────────────────────────────────────────
INSERT INTO links (id, sender_id, recipient_id, status)
VALUES
  (
    'dddddddd-dddd-dddd-dddd-dddddddddd01',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',  -- sarah
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',  -- alice
    'active'
  ),
  (
    'dddddddd-dddd-dddd-dddd-dddddddddd02',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',  -- marcus
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',  -- alice
    'active'
  ),
  (
    'dddddddd-dddd-dddd-dddd-dddddddddd03',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',  -- alice
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',  -- sarah
    'active'
  ),
  (
    'dddddddd-dddd-dddd-dddd-dddddddddd04',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',  -- marcus
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',  -- sarah
    'pending'
  )
ON CONFLICT (sender_id, recipient_id) DO NOTHING;

-- ─────────────────────────────────────────────
-- 4. Storage bucket
-- ─────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('photos', 'photos', true)
ON CONFLICT (id) DO NOTHING;

-- ─────────────────────────────────────────────
-- 5. Photos  (sent by sarah and marcus)
-- ─────────────────────────────────────────────
INSERT INTO photos (id, sender_id, storage_path, taken_at, expires_at)
VALUES
  -- Sarah's photos
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee01',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'seed/photo_1.jpg',
    now() - interval '2 hours',
    now() + interval '30 days'
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee02',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'seed/photo_2.jpg',
    now() - interval '1 day',
    now() + interval '30 days'
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee03',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'seed/photo_3.jpg',
    now() - interval '3 days',
    now() + interval '27 days'
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee04',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'seed/photo_4.jpg',
    now() - interval '5 days',
    now() + interval '2 days'   -- expiring soon!
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee05',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'seed/photo_5.jpg',
    now() - interval '7 days',
    now() + interval '23 days'
  ),
  -- Marcus's photos
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee06',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'seed/photo_6.jpg',
    now() - interval '4 hours',
    now() + interval '30 days'
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee07',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'seed/photo_7.jpg',
    now() - interval '2 days',
    now() + interval '28 days'
  ),
  (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeee08',
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'seed/photo_8.jpg',
    now() - interval '6 days',
    now() + interval '24 days'
  )
ON CONFLICT (id) DO NOTHING;

-- ─────────────────────────────────────────────
-- 6. Photo recipients  (all sent to alice)
--    photo_4 is already saved; photo_1 and photo_6 are already viewed
-- ─────────────────────────────────────────────
INSERT INTO photo_recipients (photo_id, recipient_id, delivered_at, viewed_at, saved_at)
VALUES
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee01', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '2 hours',  now() - interval '1 hour',  null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee02', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '1 day',    null,                        null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee03', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '3 days',   null,                        null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee04', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '5 days',   now() - interval '4 days',  now() - interval '4 days'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee05', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '7 days',   null,                        null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee06', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '4 hours',  now() - interval '3 hours', null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee07', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '2 days',   null,                        null),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeee08', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() - interval '6 days',   null,                        null)
ON CONFLICT (photo_id, recipient_id) DO NOTHING;
