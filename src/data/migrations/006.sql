-- Telegram context, controls, and durable sticker aliases.
ALTER TABLE telegram_updates ADD COLUMN message_id INTEGER;
ALTER TABLE telegram_updates ADD COLUMN reply_id INTEGER;
ALTER TABLE telegram_updates ADD COLUMN reply_text TEXT;
ALTER TABLE telegram_updates ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';
ALTER TABLE telegram_updates ADD COLUMN file_id TEXT;
ALTER TABLE telegram_updates ADD COLUMN file_name TEXT;
ALTER TABLE telegram_updates ADD COLUMN mime TEXT;
ALTER TABLE telegram_updates ADD COLUMN file_size INTEGER;
ALTER TABLE telegram_updates ADD COLUMN file_unique_id TEXT;
ALTER TABLE telegram_updates ADD COLUMN emoji TEXT;
ALTER TABLE telegram_updates ADD COLUMN sticker_type TEXT;
ALTER TABLE telegram_updates ADD COLUMN callback_id TEXT;
ALTER TABLE telegram_updates ADD COLUMN callback_data TEXT;
ALTER TABLE telegram_updates ADD COLUMN latitude REAL;
ALTER TABLE telegram_updates ADD COLUMN longitude REAL;

ALTER TABLE outbox ADD COLUMN reply_id INTEGER;
CREATE TABLE sticker_aliases (
  alias      TEXT PRIMARY KEY,
  file_id    TEXT NOT NULL,
  unique_id  TEXT NOT NULL,
  emoji      TEXT,
  description TEXT,
  updated    INTEGER NOT NULL
);

CREATE TABLE sticker_learning (
  id      INTEGER PRIMARY KEY CHECK (id = 1),
  alias   TEXT NOT NULL,
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL
);

CREATE TABLE sticker_cache (
  unique_id   TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  updated     INTEGER NOT NULL
);
