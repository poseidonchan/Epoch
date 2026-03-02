-- Epoch Hub v0.3: Codex session mapping + workspace provisioning queue

ALTER TABLE projects ADD COLUMN backend_engine TEXT NOT NULL DEFAULT 'pi';
ALTER TABLE projects ADD COLUMN codex_model_provider TEXT;
ALTER TABLE projects ADD COLUMN codex_model_id TEXT;
ALTER TABLE projects ADD COLUMN codex_approval_policy TEXT;
ALTER TABLE projects ADD COLUMN codex_sandbox_json TEXT;
ALTER TABLE projects ADD COLUMN hpc_workspace_path TEXT;
ALTER TABLE projects ADD COLUMN hpc_workspace_state TEXT;

ALTER TABLE sessions ADD COLUMN backend_engine TEXT NOT NULL DEFAULT 'pi';
ALTER TABLE sessions ADD COLUMN codex_thread_id TEXT;
ALTER TABLE sessions ADD COLUMN codex_model TEXT;
ALTER TABLE sessions ADD COLUMN codex_model_provider TEXT;
ALTER TABLE sessions ADD COLUMN codex_approval_policy TEXT;
ALTER TABLE sessions ADD COLUMN codex_sandbox_json TEXT;
ALTER TABLE sessions ADD COLUMN hpc_workspace_state TEXT;

ALTER TABLE threads ADD COLUMN session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS sessions_codex_thread_id_uniq
  ON sessions(codex_thread_id)
  WHERE codex_thread_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS sessions_project_backend_idx
  ON sessions(project_id, backend_engine, updated_at DESC);

CREATE INDEX IF NOT EXISTS sessions_project_thread_idx
  ON sessions(project_id, codex_thread_id);

CREATE INDEX IF NOT EXISTS threads_session_id_idx
  ON threads(session_id);

CREATE TABLE IF NOT EXISTS workspace_provisioning_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workspace_path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  requested_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS workspace_provisioning_status_idx
  ON workspace_provisioning_queue(status, updated_at, id);

CREATE INDEX IF NOT EXISTS workspace_provisioning_project_idx
  ON workspace_provisioning_queue(project_id, created_at, id);
