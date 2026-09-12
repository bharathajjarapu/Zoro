-- Reviewable learning changes; proposed text never executes.
CREATE TABLE learning_proposals (
  id             INTEGER PRIMARY KEY,
  target         TEXT NOT NULL,
  source_task    INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
  source_message INTEGER REFERENCES messages(id) ON DELETE SET NULL,
  evidence       TEXT NOT NULL,
  reason         TEXT NOT NULL,
  old_hash       TEXT NOT NULL,
  proposed       TEXT NOT NULL,
  prior_content  TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
  created        INTEGER NOT NULL,
  updated        INTEGER NOT NULL,
  applied_hash   TEXT
);
CREATE INDEX learning_proposals_status ON learning_proposals(status, id);
