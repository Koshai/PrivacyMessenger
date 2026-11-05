-- D1.1: optimistic version for concurrent call-state updates.
ALTER TABLE call_sessions
    ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
