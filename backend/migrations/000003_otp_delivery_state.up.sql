
ALTER TABLE email_challenges
ADD COLUMN delivery_status VARCHAR(16)
    NOT NULL DEFAULT 'ACTIVE';

ALTER TABLE email_challenges
ADD CONSTRAINT valid_otp_delivery_status
CHECK (
    delivery_status IN (
        'PENDING',
        'ACTIVE',
        'FAILED'
    )
);

CREATE INDEX idx_email_challenges_pending
ON email_challenges(email_normalized)
WHERE delivery_status = 'PENDING'
  AND consumed_at IS NULL;
