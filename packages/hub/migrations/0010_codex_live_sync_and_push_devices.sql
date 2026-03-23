-- Epoch Hub v0.8: codex live session sync + push device registration

CREATE TABLE IF NOT EXISTS push_devices (
  server_id TEXT NOT NULL,
  installation_id TEXT NOT NULL,
  apns_token TEXT NOT NULL,
  environment TEXT NOT NULL,
  device_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (server_id, installation_id)
);

CREATE INDEX IF NOT EXISTS push_devices_server_updated_idx
  ON push_devices(server_id, updated_at DESC, installation_id);

CREATE TABLE IF NOT EXISTS codex_live_session_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  token TEXT NOT NULL,
  server_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  reason TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS codex_live_session_events_token_id_idx
  ON codex_live_session_events(token, id);

CREATE INDEX IF NOT EXISTS codex_live_session_events_session_id_idx
  ON codex_live_session_events(session_id, id DESC);

CREATE INDEX IF NOT EXISTS codex_live_session_events_thread_id_idx
  ON codex_live_session_events(thread_id, id DESC);
