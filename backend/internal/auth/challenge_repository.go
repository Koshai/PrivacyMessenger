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

type ChallengeRepository struct {
	db *pgxpool.Pool
}

func NewChallengeRepository(db *pgxpool.Pool) *ChallengeRepository {
	return &ChallengeRepository{db: db}
}

func (r *ChallengeRepository) Create(
	ctx context.Context,
	challenge EmailChallenge,
) error {
	_, err := r.db.Exec(ctx, `
		INSERT INTO email_challenges
			(id, email_normalized, code_hash, expires_at)
		VALUES ($1, $2, $3, $4)
	`,
		challenge.ID,
		challenge.EmailNormalized,
		challenge.CodeHash,
		challenge.ExpiresAt,
	)

	if err != nil {
		return fmt.Errorf("create email challenge: %w", err)
	}

	return nil
}

func (r *ChallengeRepository) GetByID(
	ctx context.Context,
	id uuid.UUID,
) (EmailChallenge, error) {
	var challenge EmailChallenge

	err := r.db.QueryRow(ctx, `
		SELECT id, email_normalized, code_hash,
		       expires_at, consumed_at, attempts, created_at
		FROM email_challenges
		WHERE id = $1
	`, id).Scan(
		&challenge.ID,
		&challenge.EmailNormalized,
		&challenge.CodeHash,
		&challenge.ExpiresAt,
		&challenge.ConsumedAt,
		&challenge.Attempts,
		&challenge.CreatedAt,
	)

	if errors.Is(err, pgx.ErrNoRows) {
		return EmailChallenge{}, ErrChallengeNotFound
	}
	if err != nil {
		return EmailChallenge{}, fmt.Errorf("get challenge: %w", err)
	}

	return challenge, nil
}

// VerifyAndConsume atomically validates and consumes an OTP.
// A row lock prevents concurrent requests from reusing the code.
func (r *ChallengeRepository) VerifyAndConsume(
	ctx context.Context,
	id uuid.UUID,
	code string,
	secret []byte,
) error {
	tx, err := r.db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin verification: %w", err)
	}
	defer tx.Rollback(ctx)

	var challenge EmailChallenge

	err = tx.QueryRow(ctx, `
		SELECT id, email_normalized, code_hash,
		       expires_at, consumed_at, attempts, created_at
		FROM email_challenges
		WHERE id = $1
		FOR UPDATE
	`, id).Scan(
		&challenge.ID,
		&challenge.EmailNormalized,
		&challenge.CodeHash,
		&challenge.ExpiresAt,
		&challenge.ConsumedAt,
		&challenge.Attempts,
		&challenge.CreatedAt,
	)

	if errors.Is(err, pgx.ErrNoRows) {
		return ErrChallengeNotFound
	}
	if err != nil {
		return fmt.Errorf("lock challenge: %w", err)
	}

	now := time.Now().UTC()

	if challenge.ConsumedAt != nil {
		return ErrChallengeUsed
	}

	if !now.Before(challenge.ExpiresAt) {
		return ErrChallengeExpired
	}

	if challenge.Attempts >= MaxOTPAttempts {
		return ErrChallengeLocked
	}

	if !VerifyOTPHash(
		secret,
		challenge.ID.String(),
		code,
		challenge.CodeHash,
	) {
		_, err = tx.Exec(ctx, `
			UPDATE email_challenges
			SET attempts = attempts + 1
			WHERE id = $1
		`, id)
		if err != nil {
			return fmt.Errorf("increment attempts: %w", err)
		}

		// Commit the failed attempt before returning.
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("commit failed attempt: %w", err)
		}

		return ErrInvalidOTP
	}

	_, err = tx.Exec(ctx, `
		UPDATE email_challenges
		SET consumed_at = $2
		WHERE id = $1
	`, id, now)
	if err != nil {
		return fmt.Errorf("consume challenge: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit verification: %w", err)
	}

	return nil
}
