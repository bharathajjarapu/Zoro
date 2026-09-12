-- Durable Telegram intake and confirmed outbound delivery.
CREATE TABLE telegram_updates (
  id      INTEGER PRIMARY KEY,
  status  TEXT NOT NULL,
  text    TEXT NOT NULL,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL
);
CREATE INDEX telegram_updates_status ON telegram_updates(status);

ALTER TABLE outbox ADD COLUMN status TEXT NOT NULL DEFAULT 'queued';
ALTER TABLE outbox ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE outbox ADD COLUMN claimed INTEGER;
ALTER TABLE outbox ADD COLUMN error TEXT;
CREATE INDEX outbox_status ON outbox(status, id);
