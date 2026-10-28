package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type OTPIssuer struct {
	db      *pgxpool.Pool
	secret  []byte
	limiter *OTPRateLimiter
}

type IssuedOTP struct {
	ChallengeID uuid.UUID
	Code        string
	ExpiresAt   time.Time
}

func NewOTPIssuer(
	db *pgxpool.Pool,
	secret []byte,
	limiter *OTPRateLimiter,
) (*OTPIssuer, error) {
	if db == nil || limiter == nil {
		return nil, errors.New("database and limiter required")
	}
	if len(secret) < 32 {
		return nil, errors.New("OTP secret too short")
	}

	return &OTPIssuer{
		db:      db,
		secret:  append([]byte(nil), secret...),
		limiter: limiter,
	}, nil
}

// Issue creates one valid OTP challenge for an email.
// The returned code is sensitive and must only be
// passed to a trusted delivery component.
func (s *OTPIssuer) Issue(
	ctx context.Context,
	email string,
) (IssuedOTP, error) {
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return IssuedOTP{}, err
	}

	if err := s.limiter.AllowRequest(ctx, normalized); err != nil {
		return IssuedOTP{}, err
	}

	code, err := GenerateOTP()
	if err != nil {
		return IssuedOTP{}, err
	}

	id := uuid.New()
	hash, err := HashOTP(s.secret, id.String(), code)
	if err != nil {
		return IssuedOTP{}, err
	}

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return IssuedOTP{}, fmt.Errorf("begin issuance: %w", err)
	}
	defer tx.Rollback(ctx)

	// Serialize OTP issuance and verification for this email.
	if err := LockOTPEmail(ctx, tx, normalized); err != nil {
		return IssuedOTP{}, err
	}

	// Invalidate earlier unused challenges.
	_, err = tx.Exec(ctx, `
		UPDATE email_challenges
		SET consumed_at = NOW()
		WHERE email_normalized = $1
		  AND consumed_at IS NULL
	`, normalized)
	if err != nil {
		return IssuedOTP{}, fmt.Errorf("invalidate challenges: %w", err)
	}

	expiresAt := time.Now().UTC().Add(ChallengeLifetime)

	_, err = tx.Exec(ctx, `
		INSERT INTO email_challenges
			(id, email_normalized, code_hash, expires_at, delivery_status)
		VALUES ($1, $2, $3, $4, 'PENDING')
	`, id, normalized, hash, expiresAt)
	if err != nil {
		return IssuedOTP{}, fmt.Errorf("insert challenge: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return IssuedOTP{}, fmt.Errorf("commit issuance: %w", err)
	}

	return IssuedOTP{
		ChallengeID: id,
		Code:        code,
		ExpiresAt:   expiresAt,
	}, nil
}

func (s *OTPIssuer) ActivateChallenge(
	ctx context.Context,
	challengeID uuid.UUID,
) error {
	return s.transitionChallenge(
		ctx,
		challengeID,
		"ACTIVE",
	)
}

func (s *OTPIssuer) InvalidateChallenge(
	ctx context.Context,
	challengeID uuid.UUID,
) error {
	return s.transitionChallenge(
		ctx,
		challengeID,
		"FAILED",
	)
}

func (s *OTPIssuer) transitionChallenge(
	ctx context.Context,
	challengeID uuid.UUID,
	targetStatus string,
) error {
	if challengeID == uuid.Nil {
		return errors.New("challenge ID is required")
	}

	if targetStatus != "ACTIVE" && targetStatus != "FAILED" {
		return errors.New("invalid target delivery status")
	}

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin challenge transition: %w", err)
	}
	defer tx.Rollback(ctx)

	// Read the challenge's immutable email without
	// taking a row lock.
	var normalizedEmail string

	err = tx.QueryRow(ctx, `
		SELECT email_normalized
		FROM email_challenges
		WHERE id = $1
	`, challengeID).Scan(&normalizedEmail)

	if errors.Is(err, pgx.ErrNoRows) {
		return ErrChallengeNotFound
	}
	if err != nil {
		return fmt.Errorf("resolve challenge email: %w", err)
	}

	// Use the same advisory lock as issuance and login.
	if err := LockOTPEmail(
		ctx,
		tx,
		normalizedEmail,
	); err != nil {
		return err
	}

	var tag pgconn.CommandTag

	if targetStatus == "ACTIVE" {
		tag, err = tx.Exec(ctx, `
			UPDATE email_challenges
			SET delivery_status = 'ACTIVE'
			WHERE id = $1
			  AND delivery_status = 'PENDING'
			  AND consumed_at IS NULL
			  AND expires_at > NOW()
		`, challengeID)
	} else {
		tag, err = tx.Exec(ctx, `
			UPDATE email_challenges
			SET delivery_status = 'FAILED',
			    consumed_at = NOW()
			WHERE id = $1
			  AND delivery_status = 'PENDING'
			  AND consumed_at IS NULL
		`, challengeID)
	}

	if err != nil {
		return fmt.Errorf("transition challenge: %w", err)
	}

	if targetStatus == "ACTIVE" && tag.RowsAffected() != 1 {
		return errors.New("OTP challenge cannot be activated")
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit challenge transition: %w", err)
	}

	return nil
}
