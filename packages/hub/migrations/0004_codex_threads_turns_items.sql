-- Epoch Hub v0.2: Codex thread/turn/item persistence

CREATE TABLE IF NOT EXISTS threads (
  id TEXT PRIMARY KEY,
  project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
  cwd TEXT NOT NULL,
  model_provider TEXT NOT NULL,
  model_id TEXT,
  preview TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0,
  status_json TEXT,
  engine TEXT NOT NULL DEFAULT 'pi'
);

CREATE INDEX IF NOT EXISTS threads_project_id_idx ON threads(project_id);
CREATE INDEX IF NOT EXISTS threads_updated_at_idx ON threads(updated_at DESC);
CREATE INDEX IF NOT EXISTS threads_cwd_idx ON threads(cwd);
CREATE INDEX IF NOT EXISTS threads_engine_idx ON threads(engine);

CREATE TABLE IF NOT EXISTS turns (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  error_json TEXT,
  created_at INTEGER NOT NULL,
  completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS turns_thread_created_idx ON turns(thread_id, created_at);

CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS items_turn_created_idx ON items(turn_id, created_at);
CREATE INDEX IF NOT EXISTS items_thread_created_idx ON items(thread_id, created_at);

CREATE TABLE IF NOT EXISTS thread_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  event_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS thread_events_thread_created_idx ON thread_events(thread_id, created_at, id);
