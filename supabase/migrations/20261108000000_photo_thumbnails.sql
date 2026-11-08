-- Encrypted thumbnails for fast first paint.
--
--   photos.thumb_path  storage path of a small (~800px) JPEG thumbnail, sealed with the SAME content key as the
--                      full photo (AES-256-GCM, fresh random nonce), so recipients unwrap one key for both.
--                      NULL = no thumbnail (photos sent before this migration): the full photo is used instead.
--
-- Additive only. The server still only ever sees ciphertext.

alter table public.photos add column if not exists thumb_path text;
