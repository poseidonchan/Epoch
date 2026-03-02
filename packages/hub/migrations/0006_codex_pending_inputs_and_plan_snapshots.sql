-- Epoch Hub v0.4: pending user-input durability + active plan snapshots

CREATE TABLE IF NOT EXISTS codex_pending_inputs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  token TEXT NOT NULL,
  request_id TEXT NOT NULL,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  thread_id TEXT,
  method TEXT NOT NULL,
  kind TEXT NOT NULL,
  params_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  resolved_at INTEGER,
  UNIQUE (token, request_id)
);

CREATE INDEX IF NOT EXISTS codex_pending_inputs_session_status_idx
  ON codex_pending_inputs(session_id, status, created_at, id);

CREATE INDEX IF NOT EXISTS codex_pending_inputs_token_status_idx
  ON codex_pending_inputs(token, status, created_at, id);

CREATE TABLE IF NOT EXISTS codex_plan_snapshots (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  explanation TEXT,
  plan_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS codex_plan_snapshots_token_updated_idx
  ON codex_plan_snapshots(token, updated_at DESC);
