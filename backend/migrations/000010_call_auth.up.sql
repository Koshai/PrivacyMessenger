-- Dedicated call-authentication public keys and relayed handshake frames.
-- Private keys never appear here. Frames are purged when a call ends.

CREATE TABLE device_call_auth_keys (
    device_id UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    public_key BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT device_call_auth_keys_len CHECK (octet_length(public_key) = 32)
);

CREATE TABLE call_auth_frames (
    call_id UUID NOT NULL REFERENCES call_sessions(id) ON DELETE CASCADE,
    sender_user_id UUID NOT NULL,
    sender_device_id UUID NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('hello', 'confirm')),
    client_auth_id TEXT NOT NULL,
    nonce BYTEA NOT NULL CHECK (octet_length(nonce) = 32),
    call_public_key BYTEA NOT NULL CHECK (octet_length(call_public_key) = 32),
    mls_fingerprint BYTEA NOT NULL CHECK (octet_length(mls_fingerprint) = 32),
    dtls_local BYTEA CHECK (dtls_local IS NULL OR octet_length(dtls_local) = 32),
    dtls_remote BYTEA CHECK (dtls_remote IS NULL OR octet_length(dtls_remote) = 32),
    signature BYTEA NOT NULL CHECK (octet_length(signature) = 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (call_id, sender_device_id, kind),
    UNIQUE (client_auth_id)
);

CREATE INDEX idx_call_auth_frames_call ON call_auth_frames (call_id);
