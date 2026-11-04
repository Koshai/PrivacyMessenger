-- Per-conversation durable ordering: sequence allocated in the same
-- transaction as the envelope insert (commit order == seq order).

ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS next_envelope_seq BIGINT NOT NULL DEFAULT 0;

ALTER TABLE message_envelopes
    ADD COLUMN IF NOT EXISTS conversation_seq BIGINT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_message_envelopes_conversation_seq_unique
    ON message_envelopes (conversation_id, conversation_seq)
    WHERE conversation_seq IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_message_envelopes_conversation_seq_asc
    ON message_envelopes (conversation_id, conversation_seq ASC);
