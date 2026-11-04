-- MLS device identity registration + one-time key packages (server-blind bytes).
-- Conversation ↔ MLS group mapping for opaque envelope delivery.

CREATE TABLE device_mls_identities (
    device_id UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    public_identity_key BYTEA NOT NULL,
    fingerprint_hex CHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ,
    CONSTRAINT device_mls_identities_pubkey_nonempty
        CHECK (octet_length(public_identity_key) > 0),
    CONSTRAINT device_mls_identities_fingerprint_len
        CHECK (char_length(fingerprint_hex) = 64)
);

CREATE INDEX idx_device_mls_identities_user
    ON device_mls_identities (user_id)
    WHERE revoked_at IS NULL;

CREATE TABLE mls_key_packages (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    key_package BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    reserved_at TIMESTAMPTZ,
    reserved_by_user_id UUID REFERENCES users(id),
    CONSTRAINT mls_key_packages_bytes_nonempty
        CHECK (octet_length(key_package) > 0),
    CONSTRAINT mls_key_packages_expiry_after_create
        CHECK (expires_at > created_at)
);

CREATE INDEX idx_mls_key_packages_available
    ON mls_key_packages (user_id, expires_at)
    WHERE consumed_at IS NULL AND reserved_at IS NULL;

CREATE INDEX idx_mls_key_packages_device
    ON mls_key_packages (device_id);

ALTER TABLE conversations
    ADD COLUMN mls_group_id_hex VARCHAR(128),
    ADD COLUMN mls_initiator_id UUID REFERENCES users(id),
    ADD COLUMN mls_established_at TIMESTAMPTZ;

CREATE UNIQUE INDEX idx_conversations_mls_group
    ON conversations (mls_group_id_hex)
    WHERE mls_group_id_hex IS NOT NULL;

-- Deterministic delivery ordering within a conversation.
ALTER TABLE message_envelopes
    ADD COLUMN seq BIGINT;

CREATE SEQUENCE message_envelopes_seq_seq;

CREATE OR REPLACE FUNCTION assign_message_envelope_seq()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.seq IS NULL THEN
        NEW.seq := nextval('message_envelopes_seq_seq');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_message_envelopes_seq
    BEFORE INSERT ON message_envelopes
    FOR EACH ROW
    EXECUTE PROCEDURE assign_message_envelope_seq();

CREATE INDEX idx_message_envelopes_conversation_seq
    ON message_envelopes (conversation_id, seq);
