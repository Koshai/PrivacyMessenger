CREATE TABLE friendships (
    id UUID PRIMARY KEY,
    requester_id UUID NOT NULL REFERENCES users(id),
    addressee_id UUID NOT NULL REFERENCES users(id),
    status VARCHAR(16) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT friendships_no_self CHECK (requester_id <> addressee_id),
    CONSTRAINT friendships_valid_status CHECK (
        status IN ('PENDING', 'ACCEPTED', 'REJECTED')
    )
);

CREATE UNIQUE INDEX idx_friendships_pending_pair
    ON friendships (requester_id, addressee_id)
    WHERE status = 'PENDING';

CREATE UNIQUE INDEX idx_friendships_accepted_pair
    ON friendships (
        LEAST(requester_id, addressee_id),
        GREATEST(requester_id, addressee_id)
    )
    WHERE status = 'ACCEPTED';

CREATE INDEX idx_friendships_addressee_pending
    ON friendships (addressee_id)
    WHERE status = 'PENDING';

CREATE INDEX idx_friendships_requester_pending
    ON friendships (requester_id)
    WHERE status = 'PENDING';

CREATE INDEX idx_friendships_user_accepted
    ON friendships (requester_id, addressee_id)
    WHERE status = 'ACCEPTED';

CREATE TABLE user_blocks (
    blocker_id UUID NOT NULL REFERENCES users(id),
    blocked_id UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT user_blocks_no_self CHECK (blocker_id <> blocked_id)
);

CREATE INDEX idx_user_blocks_blocked
    ON user_blocks (blocked_id);

CREATE TABLE friend_request_limits (
    requester_id UUID PRIMARY KEY REFERENCES users(id),
    window_started_at TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT friend_request_count_nonnegative
        CHECK (request_count >= 0)
);
