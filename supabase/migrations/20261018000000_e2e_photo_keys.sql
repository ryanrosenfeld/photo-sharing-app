-- End-to-end encrypted photos.
--
--   profiles.public_key           base64 DER (SPKI) of the user's P-256 key-agreement public key. The private key
--                                 never leaves the user's devices.
--   photo_recipients.wrapped_key  the photo's content key wrapped to that recipient's public key (base64:
--                                 65-byte ephemeral public key || AES-GCM combined box). NULL = legacy plaintext photo.
--
-- Additive only: photos shared before this migration stay readable as before. New blobs in the `photos` bucket are
-- ciphertext, so the bucket's public-read policy no longer exposes photo content.

alter table public.profiles add column if not exists public_key text;
alter table public.photo_recipients add column if not exists wrapped_key text;
