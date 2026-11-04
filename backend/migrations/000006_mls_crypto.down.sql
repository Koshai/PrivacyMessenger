DROP TRIGGER IF EXISTS trg_message_envelopes_seq ON message_envelopes;
DROP FUNCTION IF EXISTS assign_message_envelope_seq();
DROP SEQUENCE IF EXISTS message_envelopes_seq_seq;
DROP INDEX IF EXISTS idx_message_envelopes_conversation_seq;
ALTER TABLE message_envelopes DROP COLUMN IF EXISTS seq;

DROP INDEX IF EXISTS idx_conversations_mls_group;
ALTER TABLE conversations
    DROP COLUMN IF EXISTS mls_group_id_hex,
    DROP COLUMN IF EXISTS mls_initiator_id,
    DROP COLUMN IF EXISTS mls_established_at;

DROP TABLE IF EXISTS mls_key_packages;
DROP TABLE IF EXISTS device_mls_identities;
