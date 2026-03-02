-- Epoch Hub v0.1: project upload extraction + indexing metadata

CREATE TABLE IF NOT EXISTS project_file_index (
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  artifact_path TEXT NOT NULL,
  upload_id TEXT REFERENCES uploads(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'processing',
  extractor TEXT,
  extracted_text TEXT,
  summary TEXT,
  summary_model TEXT,
  embedding_model TEXT,
  embedding_dim INTEGER,
  chunks_count INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  completed_at TEXT,
  PRIMARY KEY (project_id, artifact_path)
);

CREATE INDEX IF NOT EXISTS project_file_index_project_status_idx
  ON project_file_index(project_id, status);

CREATE TABLE IF NOT EXISTS project_file_chunk (
  project_id TEXT NOT NULL,
  artifact_path TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  content TEXT NOT NULL,
  token_estimate INTEGER,
  embedding_json TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (project_id, artifact_path, chunk_index),
  FOREIGN KEY (project_id, artifact_path)
    REFERENCES project_file_index(project_id, artifact_path)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS project_file_chunk_project_idx
  ON project_file_chunk(project_id);
