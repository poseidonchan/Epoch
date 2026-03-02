-- Epoch Hub v0.6: AGENTS.md sync audit

CREATE TABLE IF NOT EXISTS project_agents_sync_events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  action TEXT NOT NULL,
  hash TEXT,
  ts TEXT NOT NULL,
  error TEXT
);

CREATE INDEX IF NOT EXISTS project_agents_sync_events_project_ts_idx
  ON project_agents_sync_events(project_id, ts DESC, id DESC);

