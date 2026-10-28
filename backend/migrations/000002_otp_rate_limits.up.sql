
CREATE TABLE otp_request_limits (
    email_normalized VARCHAR(320) PRIMARY KEY,
    window_started_at TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT otp_request_count_nonnegative
        CHECK (request_count >= 0)
);

CREATE INDEX idx_otp_request_limits_window
    ON otp_request_limits(window_started_at);
