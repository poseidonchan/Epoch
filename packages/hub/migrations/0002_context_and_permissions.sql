-- LabOS Hub v0.1: session context stats + permissions

ALTER TABLE sessions ADD COLUMN permission_level TEXT NOT NULL DEFAULT 'default';
ALTER TABLE sessions ADD COLUMN context_model_id TEXT;
ALTER TABLE sessions ADD COLUMN context_window_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN context_used_input_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN context_used_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN context_updated_at TEXT;
ALTER TABLE sessions ADD COLUMN last_compacted_at TEXT;

ALTER TABLE runs ADD COLUMN permission_level TEXT;
