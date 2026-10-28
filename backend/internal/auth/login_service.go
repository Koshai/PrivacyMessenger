package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const SessionLifetime = 30 * 24 * time.Hour

var ErrAccountDeleted = errors.New("account is unavailable")
var ErrChallengeNotActive = errors.New("OTP challenge is not active")

type LoginService struct {
	db     *pgxpool.Pool
	secret []byte

	// Test seam: allows integration tests to simulate
	// a failure before inserting the new session.
	beforeSessionInsert func() error
}

type LoginResult struct {
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	Token     string
	ExpiresAt time.Time
}

func NewLoginService(
	db *pgxpool.Pool,
	secret []byte,
) (*LoginService, error) {
	if db == nil {
		return nil, errors.New("database pool is required")
	}
	if len(secret) < 32 {
		return nil, errors.New("OTP secret must be at least 32 bytes")
	}

	return &LoginService{
		db:     db,
		secret: append([]byte(nil), secret...),
	}, nil
}

func (s *LoginService) VerifyAndLogin(
	ctx context.Context,
	challengeID uuid.UUID,
	code string,
	deviceName string,
) (LoginResult, error) {
	if challengeID == uuid.Nil {
		return LoginResult{}, ErrChallengeNotFound
	}
	if len(deviceName) > 120 {
		return LoginResult{}, errors.New("device name too long")
	}

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return LoginResult{}, fmt.Errorf("begin login: %w", err)
	}

	defer tx.Rollback(ctx)

	// First determine which email owns the challenge.
	// This lookup deliberately does not lock the row.
	var normalizedEmail string

	err = tx.QueryRow(ctx, `
		SELECT email_normalized
		FROM email_challenges
		WHERE id = $1
	`, challengeID).Scan(&normalizedEmail)

	if errors.Is(err, pgx.ErrNoRows) {
		return LoginResult{}, ErrChallengeNotFound
	}
	if err != nil {
		return LoginResult{}, fmt.Errorf(
			"resolve challenge email: %w", err,
		)
	}

	// Acquire the same email-level advisory lock used
	// by OTP issuance, before locking the challenge row.
	if err := LockOTPEmail(
		ctx,
		tx,
		normalizedEmail,
	); err != nil {
		return LoginResult{}, err
	}

	var challenge EmailChallenge
	var deliveryStatus string

	err = tx.QueryRow(ctx, `
		SELECT id, email_normalized, code_hash,
		       expires_at, consumed_at, attempts, created_at, delivery_status
		FROM email_challenges
		WHERE id = $1
		FOR UPDATE
	`, challengeID).Scan(
		&challenge.ID,
		&challenge.EmailNormalized,
		&challenge.CodeHash,
		&challenge.ExpiresAt,
		&challenge.ConsumedAt,
		&challenge.Attempts,
		&challenge.CreatedAt,
		&deliveryStatus,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return LoginResult{}, ErrChallengeNotFound
	}
	if err != nil {
		return LoginResult{}, fmt.Errorf("lock challenge: %w", err)
	}

	now := time.Now().UTC()

	if challenge.ConsumedAt != nil {
		return LoginResult{}, ErrChallengeUsed
	}
	if deliveryStatus != "ACTIVE" {
		return LoginResult{}, ErrChallengeNotActive
	}
	if !now.Before(challenge.ExpiresAt) {
		return LoginResult{}, ErrChallengeExpired
	}
	if challenge.Attempts >= MaxOTPAttempts {
		return LoginResult{}, ErrChallengeLocked
	}

	if !VerifyOTPHash(
		s.secret,
		challenge.ID.String(),
		code,
		challenge.CodeHash,
	) {
		_, err := tx.Exec(ctx, `
			UPDATE email_challenges
			SET attempts = attempts + 1
			WHERE id = $1
		`, challengeID)
		if err != nil {
			return LoginResult{}, fmt.Errorf("increment attempts: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return LoginResult{}, fmt.Errorf("commit attempt: %w", err)
		}
		return LoginResult{}, ErrInvalidOTP
	}

	// Create a new account or reuse an active account.
	// A soft-deleted account must never be reactivated
	// through the normal OTP login flow.
	var userID uuid.UUID

	err = tx.QueryRow(ctx, `
		INSERT INTO users (id, email, email_normalized)
		VALUES ($1, $2, $2)
		ON CONFLICT (email_normalized)
		DO UPDATE SET updated_at = NOW()
		WHERE users.deleted_at IS NULL
		RETURNING id
	`, uuid.New(), challenge.EmailNormalized).Scan(&userID)

	if errors.Is(err, pgx.ErrNoRows) {
		return LoginResult{}, ErrAccountDeleted
	}

	if err != nil {
		return LoginResult{}, fmt.Errorf("resolve user: %w", err)
	}

	// Serialize concurrent logins for the same user.
	var lockedUserID uuid.UUID
	err = tx.QueryRow(ctx, `
		SELECT id FROM users WHERE id = $1 FOR UPDATE
	`, userID).Scan(&lockedUserID)
	if err != nil {
		return LoginResult{}, fmt.Errorf("lock user: %w", err)
	}

	deviceID := uuid.New()

	_, err = tx.Exec(ctx, `
		INSERT INTO devices (id, user_id, device_name)
		VALUES ($1, $2, $3)
	`, deviceID, userID, deviceName)
	if err != nil {
		return LoginResult{}, fmt.Errorf("register device: %w", err)
	}

	_, err = tx.Exec(ctx, `
		UPDATE sessions
		SET revoked_at = $2
		WHERE user_id = $1 AND revoked_at IS NULL
	`, userID, now)
	if err != nil {
		return LoginResult{}, fmt.Errorf("revoke old sessions: %w", err)
	}

	if s.beforeSessionInsert != nil {
		if err := s.beforeSessionInsert(); err != nil {
			return LoginResult{}, fmt.Errorf(
				"before session insert: %w", err,
			)
		}
	}

	token, err := GenerateSessionToken()
	if err != nil {
		return LoginResult{}, err
	}
	tokenHash := HashSessionToken(token)
	expiresAt := now.Add(SessionLifetime)

	_, err = tx.Exec(ctx, `
		INSERT INTO sessions
			(id, user_id, device_id, token_hash, expires_at)
		VALUES ($1, $2, $3, $4, $5)
	`, uuid.New(), userID, deviceID, tokenHash[:], expiresAt)
	if err != nil {
		return LoginResult{}, fmt.Errorf("create session: %w", err)
	}

	_, err = tx.Exec(ctx, `
		UPDATE email_challenges
		SET consumed_at = $2
		WHERE id = $1
	`, challengeID, now)
	if err != nil {
		return LoginResult{}, fmt.Errorf("consume OTP: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return LoginResult{}, fmt.Errorf("commit login: %w", err)
	}

	return LoginResult{
		UserID:    userID,
		DeviceID:  deviceID,
		Token:     token,
		ExpiresAt: expiresAt,
	}, nil
}
