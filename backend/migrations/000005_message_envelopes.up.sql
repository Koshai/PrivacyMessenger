CREATE TABLE conversations (
    id UUID PRIMARY KEY,
    user_a UUID NOT NULL REFERENCES users(id),
    user_b UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT conversations_ordered_pair CHECK (user_a < user_b),
    CONSTRAINT conversations_distinct_users CHECK (user_a <> user_b)
);

CREATE UNIQUE INDEX idx_conversations_pair
    ON conversations (user_a, user_b);

CREATE TABLE message_envelopes (
    id UUID PRIMARY KEY,
    conversation_id UUID NOT NULL REFERENCES conversations(id),
    sender_id UUID NOT NULL REFERENCES users(id),
    client_message_id VARCHAR(128) NOT NULL,
    ciphertext BYTEA NOT NULL,
    content_type VARCHAR(64) NOT NULL DEFAULT 'application/octet-stream',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT message_envelopes_ciphertext_nonempty CHECK (octet_length(ciphertext) > 0),
    CONSTRAINT message_envelopes_client_id_nonempty CHECK (char_length(client_message_id) > 0)
);

CREATE UNIQUE INDEX idx_message_envelopes_idempotent
    ON message_envelopes (conversation_id, sender_id, client_message_id);

CREATE INDEX idx_message_envelopes_conversation_created
    ON message_envelopes (conversation_id, created_at DESC, id DESC);

CREATE TABLE message_deliveries (
    envelope_id UUID NOT NULL REFERENCES message_envelopes(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id),
    delivered_at TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    PRIMARY KEY (envelope_id, recipient_id)
);

CREATE INDEX idx_message_deliveries_recipient_pending
    ON message_deliveries (recipient_id, envelope_id)
    WHERE acknowledged_at IS NULL;
