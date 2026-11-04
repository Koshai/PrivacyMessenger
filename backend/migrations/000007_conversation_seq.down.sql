DROP INDEX IF EXISTS idx_message_envelopes_conversation_seq_asc;
DROP INDEX IF EXISTS idx_message_envelopes_conversation_seq_unique;
ALTER TABLE message_envelopes DROP COLUMN IF EXISTS conversation_seq;
ALTER TABLE conversations DROP COLUMN IF EXISTS next_envelope_seq;
