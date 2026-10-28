package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrOTPRateLimited = errors.New("OTP request rate limit exceeded")

const (
	OTPRequestWindow = 15 * time.Minute
	MaxOTPRequests   = 3
)

type OTPRateLimiter struct {
	db *pgxpool.Pool
}

func NewOTPRateLimiter(db *pgxpool.Pool) *OTPRateLimiter {
	return &OTPRateLimiter{db: db}
}

// AllowRequest atomically consumes one request allowance.
// This counter is independent of whether an email is delivered.

func (r *OTPRateLimiter) AllowRequest(
	ctx context.Context,
	emailNormalized string,
) error {
	var allowed bool

	err := r.db.QueryRow(ctx, `
		WITH attempt AS (
			INSERT INTO otp_request_limits
				(email_normalized, window_started_at, request_count)
			VALUES ($1, NOW(), 1)
			ON CONFLICT (email_normalized)
			DO UPDATE SET
				window_started_at = CASE
					WHEN otp_request_limits.window_started_at
					     <= NOW() - INTERVAL '15 minutes'
					THEN NOW()
					ELSE otp_request_limits.window_started_at
				END,
				request_count = CASE
					WHEN otp_request_limits.window_started_at
					     <= NOW() - INTERVAL '15 minutes'
					THEN 1
					ELSE otp_request_limits.request_count + 1
				END
			RETURNING request_count
		)
		SELECT request_count <= $2 FROM attempt
	`, emailNormalized, MaxOTPRequests).Scan(&allowed)

	if err != nil {
		return fmt.Errorf("check OTP request limit: %w", err)
	}

	if !allowed {
		return ErrOTPRateLimited
	}

	return nil
}
