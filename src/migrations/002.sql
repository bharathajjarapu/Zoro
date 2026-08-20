-- Outbound queue. The agent never learns about Telegram; it appends here and
-- whichever driver is running (bot or CLI) drains it after the turn.
CREATE TABLE outbox (
  id      INTEGER PRIMARY KEY,
  kind    TEXT    NOT NULL,           -- 'text' | 'photo' | 'document'
  path    TEXT,                       -- workspace-relative, NULL for 'text'
  text    TEXT    NOT NULL,           -- caption for a file, body for 'text'
  created INTEGER NOT NULL
);

-- Runs the scheduler declined to replay after downtime.
ALTER TABLE routines ADD COLUMN skips INTEGER NOT NULL DEFAULT 0;
