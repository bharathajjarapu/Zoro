ALTER TABLE approvals ADD COLUMN updated INTEGER;
UPDATE approvals SET updated = created WHERE updated IS NULL;
ALTER TABLE messages ADD COLUMN owner_text TEXT;
ALTER TABLE telegram_updates ADD COLUMN owner_text TEXT;
