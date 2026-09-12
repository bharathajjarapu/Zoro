CREATE TABLE IF NOT EXISTS facts (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 1.0,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  expires INTEGER
);

CREATE TABLE IF NOT EXISTS diary (
  day TEXT PRIMARY KEY,
  summary TEXT NOT NULL,
  created INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
  text,
  kind UNINDEXED,
  ref UNINDEXED,
  tokenize = 'porter'
);

CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  ref INTEGER,
  created INTEGER NOT NULL,
  owner_text TEXT
);
CREATE INDEX IF NOT EXISTS messages_created ON messages(created);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(ref, id);

CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY,
  parent INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  prio INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL,
  goal TEXT NOT NULL,
  model TEXT,
  tools TEXT,
  result TEXT,
  tries INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  due INTEGER
);
CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS tasks_parent ON tasks(parent);

CREATE TABLE IF NOT EXISTS routines (
  name TEXT PRIMARY KEY,
  next INTEGER,
  last INTEGER,
  status TEXT,
  fails INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 0,
  skips INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS routines_next ON routines(next) WHERE enabled = 1;

CREATE TABLE IF NOT EXISTS approvals (
  id INTEGER PRIMARY KEY,
  task INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
  tool TEXT NOT NULL,
  args TEXT NOT NULL,
  target TEXT,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL,
  updated INTEGER
);
CREATE INDEX IF NOT EXISTS approvals_status ON approvals(status);

CREATE TABLE IF NOT EXISTS secrets (
  name TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  host TEXT NOT NULL,
  created INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  path TEXT,
  text TEXT NOT NULL,
  created INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  claimed INTEGER,
  error TEXT,
  reply_id INTEGER,
  next_attempt INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS outbox_status ON outbox(status, id);
CREATE INDEX IF NOT EXISTS outbox_ready ON outbox(status, next_attempt, id);

CREATE TABLE IF NOT EXISTS telegram_updates (
  id INTEGER PRIMARY KEY,
  status TEXT NOT NULL,
  text TEXT NOT NULL,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  message_id INTEGER,
  reply_id INTEGER,
  reply_text TEXT,
  kind TEXT NOT NULL DEFAULT 'text',
  file_id TEXT,
  preview_id TEXT,
  file_name TEXT,
  mime TEXT,
  file_size INTEGER,
  file_unique_id TEXT,
  emoji TEXT,
  sticker_type TEXT,
  callback_id TEXT,
  callback_data TEXT,
  latitude REAL,
  longitude REAL,
  owner_text TEXT
);
CREATE INDEX IF NOT EXISTS telegram_updates_status ON telegram_updates(status);

CREATE TABLE IF NOT EXISTS learning_proposals (
  id INTEGER PRIMARY KEY,
  target TEXT NOT NULL,
  source_task INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
  source_message INTEGER REFERENCES messages(id) ON DELETE SET NULL,
  evidence TEXT NOT NULL,
  reason TEXT NOT NULL,
  old_hash TEXT NOT NULL,
  proposed TEXT NOT NULL,
  prior_content TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  applied_hash TEXT
);
CREATE INDEX IF NOT EXISTS learning_proposals_status ON learning_proposals(status, id);

CREATE TABLE IF NOT EXISTS sticker_aliases (
  alias TEXT PRIMARY KEY,
  file_id TEXT NOT NULL,
  unique_id TEXT NOT NULL,
  emoji TEXT,
  description TEXT,
  updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sticker_learning (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  alias TEXT NOT NULL,
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL
);
