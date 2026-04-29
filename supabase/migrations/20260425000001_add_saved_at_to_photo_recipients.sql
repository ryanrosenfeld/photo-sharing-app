ALTER TABLE photo_recipients
  ADD COLUMN IF NOT EXISTS saved_at timestamptz;
