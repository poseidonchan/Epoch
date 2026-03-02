-- Epoch Hub v0.1 initial schema

CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  lifecycle TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_message_preview TEXT,
  last_message_at TEXT
);

CREATE INDEX IF NOT EXISTS sessions_project_id_idx ON sessions(project_id);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  initiated_at TEXT NOT NULL,
  completed_at TEXT,
  current_step INTEGER NOT NULL,
  total_steps INTEGER NOT NULL,
  log_snippet TEXT NOT NULL,
  step_titles TEXT NOT NULL,
  produced_artifact_paths TEXT NOT NULL,
  hpc_job_id TEXT
);

CREATE INDEX IF NOT EXISTS runs_project_id_idx ON runs(project_id);
CREATE INDEX IF NOT EXISTS runs_session_id_idx ON runs(session_id);

CREATE TABLE IF NOT EXISTS artifacts (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  kind TEXT NOT NULL,
  origin TEXT NOT NULL,
  modified_at TEXT NOT NULL,
  size_bytes INTEGER,
  created_by_session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  created_by_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  UNIQUE (project_id, path)
);

CREATE INDEX IF NOT EXISTS artifacts_project_id_idx ON artifacts(project_id);

CREATE TABLE IF NOT EXISTS uploads (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  original_name TEXT NOT NULL,
  stored_path TEXT NOT NULL,
  content_type TEXT,
  size_bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  created_by_session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS uploads_project_id_idx ON uploads(project_id);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  ts TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  artifact_refs TEXT NOT NULL,
  proposed_plan TEXT,
  run_id TEXT,
  parent_id TEXT
);

CREATE INDEX IF NOT EXISTS messages_session_ts_idx ON messages(session_id, ts);
CREATE INDEX IF NOT EXISTS messages_project_id_idx ON messages(project_id);

CREATE TABLE IF NOT EXISTS plans (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  agent_run_id TEXT NOT NULL,
  status TEXT NOT NULL,
  plan TEXT NOT NULL,
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  decision TEXT,
  resolved_by_device_id TEXT
);

CREATE INDEX IF NOT EXISTS plans_session_id_idx ON plans(session_id);

CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  version TEXT NOT NULL,
  caps TEXT NOT NULL,
  commands TEXT NOT NULL,
  permissions TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS nodes_device_id_idx ON nodes(device_id);
