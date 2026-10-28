DROP INDEX IF EXISTS idx_email_challenges_pending;

ALTER TABLE email_challenges
DROP CONSTRAINT IF EXISTS valid_otp_delivery_status;

ALTER TABLE email_challenges
DROP COLUMN IF EXISTS delivery_status;