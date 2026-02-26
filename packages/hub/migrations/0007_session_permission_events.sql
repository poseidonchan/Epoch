-- LabOS Hub v0.5: session permission audit events

CREATE TABLE IF NOT EXISTS session_permission_events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  level TEXT NOT NULL,
  previous_level TEXT,
  changed_by_device_id TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS session_permission_events_session_created_idx
  ON session_permission_events(session_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS session_permission_events_project_created_idx
  ON session_permission_events(project_id, created_at DESC, id DESC);

