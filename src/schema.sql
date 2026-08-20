-- The accepted schema from docs/ARCHITECTURE.md. Connection pragmas
-- (foreign_keys, WAL, ...) live in db.zig; this file is pure DDL.

-- ── durable memory ────────────────────────────────────────────────────────
CREATE TABLE facts (
  id         INTEGER PRIMARY KEY,
  key        TEXT    NOT NULL UNIQUE,
  value      TEXT    NOT NULL,
  source     TEXT    NOT NULL,           -- 'owner' | 'inferred'
  confidence REAL    NOT NULL DEFAULT 1.0,
  created    INTEGER NOT NULL,
  updated    INTEGER NOT NULL,
  expires    INTEGER                     -- NULL = never
);

CREATE TABLE diary (
  day     TEXT    PRIMARY KEY,           -- 'YYYY-MM-DD'
  summary TEXT    NOT NULL,
  created INTEGER NOT NULL
);

CREATE VIRTUAL TABLE chunks USING fts5(
  text,
  kind UNINDEXED,                        -- 'fact' | 'diary'
  ref  UNINDEXED,                        -- facts.key or diary.day
  tokenize = 'porter'
);

-- ── transcript (deleted nightly once the diary commits) ───────────────────
CREATE TABLE messages (
  id      INTEGER PRIMARY KEY,
  role    TEXT    NOT NULL,              -- 'user' | 'assistant' | 'tool'
  content TEXT    NOT NULL,
  ref     INTEGER,                       -- telegram message id, NULL from cli
  created INTEGER NOT NULL
);
CREATE INDEX messages_created ON messages(created);

-- ── work ──────────────────────────────────────────────────────────────────
CREATE TABLE tasks (
  id      INTEGER PRIMARY KEY,
  parent  INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
  status  TEXT    NOT NULL,              -- queued|running|blocked|done|failed|cancelled
  prio    INTEGER NOT NULL DEFAULT 0,
  summary TEXT    NOT NULL,
  goal    TEXT    NOT NULL,              -- success criterion
  model   TEXT,                          -- profile name
  tools   TEXT,                          -- JSON array; NULL = inherit
  result  TEXT,
  tries   INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  due     INTEGER
);
CREATE INDEX tasks_status ON tasks(status);
CREATE INDEX tasks_parent ON tasks(parent);

CREATE TABLE routines (
  name    TEXT    PRIMARY KEY,           -- matches /skills/<name>/SKILL.md
  next    INTEGER,
  last    INTEGER,
  status  TEXT,
  fails   INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 0     -- mutating routines start off
);
CREATE INDEX routines_next ON routines(next) WHERE enabled = 1;

CREATE TABLE approvals (
  id      INTEGER PRIMARY KEY,
  task    INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
  tool    TEXT    NOT NULL,
  args    TEXT    NOT NULL,              -- JSON: the exact bound arguments
  target  TEXT,
  reason  TEXT    NOT NULL,
  status  TEXT    NOT NULL DEFAULT 'pending',
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL
);
CREATE INDEX approvals_status ON approvals(status);

-- ── infrastructure ────────────────────────────────────────────────────────
CREATE TABLE secrets (
  name    TEXT    PRIMARY KEY,
  value   TEXT    NOT NULL,
  host    TEXT    NOT NULL,              -- the one approved host
  created INTEGER NOT NULL
);

CREATE TABLE kv (
  key   TEXT PRIMARY KEY,                -- 'tg_offset', 'spend_today', ...
  value TEXT NOT NULL
);
