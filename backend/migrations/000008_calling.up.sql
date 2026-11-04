-- One-to-one call sessions and ephemeral signaling (D1).
-- SDP/ICE are retained only while a call is non-terminal, then cleared.

CREATE TABLE call_sessions (
    id UUID PRIMARY KEY,
    caller_user_id UUID NOT NULL REFERENCES users(id),
    callee_user_id UUID NOT NULL REFERENCES users(id),
    caller_device_id UUID NOT NULL REFERENCES devices(id),
    callee_device_id UUID REFERENCES devices(id),
    media_type VARCHAR(16) NOT NULL,
    state VARCHAR(32) NOT NULL,
    end_reason VARCHAR(32),
    client_call_id VARCHAR(128) NOT NULL,
    sdp_offer TEXT,
    sdp_answer TEXT,
    ring_expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accepted_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    CONSTRAINT call_sessions_media_type_check
        CHECK (media_type IN ('audio', 'video')),
    CONSTRAINT call_sessions_state_check
        CHECK (state IN ('ringing', 'accepted', 'connected', 'ended')),
    CONSTRAINT call_sessions_end_reason_check
        CHECK (
            end_reason IS NULL
            OR end_reason IN (
                'declined', 'cancelled', 'hangup', 'timeout',
                'revoked', 'busy', 'failed'
            )
        ),
    CONSTRAINT call_sessions_no_self CHECK (caller_user_id <> callee_user_id),
    CONSTRAINT call_sessions_client_call_id_len
        CHECK (char_length(client_call_id) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX idx_call_sessions_caller_client_id
    ON call_sessions (caller_user_id, client_call_id);

CREATE INDEX idx_call_sessions_participants_active
    ON call_sessions (caller_user_id, callee_user_id, state)
    WHERE state <> 'ended';

CREATE INDEX idx_call_sessions_ring_expires
    ON call_sessions (ring_expires_at)
    WHERE state = 'ringing';

CREATE TABLE call_ice_candidates (
    id UUID PRIMARY KEY,
    call_id UUID NOT NULL REFERENCES call_sessions(id) ON DELETE CASCADE,
    sender_user_id UUID NOT NULL REFERENCES users(id),
    seq BIGINT NOT NULL,
    candidate TEXT NOT NULL,
    sdp_mid TEXT,
    sdp_mline_index INT,
    client_ice_id VARCHAR(128) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT call_ice_candidates_candidate_nonempty
        CHECK (char_length(candidate) BETWEEN 1 AND 4096),
    CONSTRAINT call_ice_candidates_client_ice_id_len
        CHECK (char_length(client_ice_id) BETWEEN 1 AND 128)
);

CREATE UNIQUE INDEX idx_call_ice_client_id
    ON call_ice_candidates (call_id, sender_user_id, client_ice_id);

CREATE UNIQUE INDEX idx_call_ice_seq
    ON call_ice_candidates (call_id, seq);

CREATE INDEX idx_call_ice_call_created
    ON call_ice_candidates (call_id, created_at);
