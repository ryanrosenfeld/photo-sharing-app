-- Verification personas for LOCAL Supabase only (supabase db reset applies this file; see config.toml).
-- Test accounts: <name>@test.local, password Test1234! (local-only throwaway credentials).
--
--   alice  free   alice <-> bob active links (each sends photos of the other to the other)
--   bob    free   face_profile_enabled (reference photos uploaded by scripts/verify/run_scenario.sh)
--   carol  pro    carol -> alice pending request (Alice accepts it in a scenario)
--   dan    free   no links (clean slate for friend-request scenarios)
-- Link semantics (current code): sender -> recipient = sender's phone auto-shares photos of the
-- recipient's face with the recipient.

create extension if not exists pgcrypto;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) values
  ('00000000-0000-0000-0000-000000000000','a1111111-1111-1111-1111-111111111111','authenticated','authenticated','alice@test.local',crypt('Test1234!',gen_salt('bf',10)),now(),'{"provider":"email","providers":["email"]}','{"display_name":"Alice"}',now(),now(),'','','',''),
  ('00000000-0000-0000-0000-000000000000','b2222222-2222-2222-2222-222222222222','authenticated','authenticated','bob@test.local',crypt('Test1234!',gen_salt('bf',10)),now(),'{"provider":"email","providers":["email"]}','{"display_name":"Bob"}',now(),now(),'','','',''),
  ('00000000-0000-0000-0000-000000000000','c3333333-3333-3333-3333-333333333333','authenticated','authenticated','carol@test.local',crypt('Test1234!',gen_salt('bf',10)),now(),'{"provider":"email","providers":["email"]}','{"display_name":"Carol"}',now(),now(),'','','',''),
  ('00000000-0000-0000-0000-000000000000','d4444444-4444-4444-4444-444444444444','authenticated','authenticated','dan@test.local',crypt('Test1234!',gen_salt('bf',10)),now(),'{"provider":"email","providers":["email"]}','{"display_name":"Dan"}',now(),now(),'','','','')
on conflict (id) do nothing;

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), 'email', now(), now(), now()
from auth.users u where u.email like '%@test.local'
on conflict do nothing;

-- handle_new_user trigger already created profiles; set the persona specifics.
update public.profiles set plan = 'pro' where id = 'c3333333-3333-3333-3333-333333333333';
-- Onboarding requires a face profile, so every persona counts as onboarded for that step
-- (bob's reference photos are uploaded by scripts/verify/run_scenario.sh; the others never serve as the enrollment source).
update public.profiles set face_profile_enabled = true;

insert into public.links (sender_id, recipient_id, status) values
  ('a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','active'),
  ('b2222222-2222-2222-2222-222222222222','a1111111-1111-1111-1111-111111111111','active'),
  ('c3333333-3333-3333-3333-333333333333','a1111111-1111-1111-1111-111111111111','pending')
on conflict do nothing;

insert into storage.buckets (id, name, public) values ('photos', 'photos', true) on conflict (id) do nothing;
