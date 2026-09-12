ALTER TABLE outbox ADD COLUMN next_attempt INTEGER NOT NULL DEFAULT 0;
CREATE INDEX outbox_ready ON outbox(status, next_attempt, id);
