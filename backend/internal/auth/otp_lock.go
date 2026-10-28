package auth

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// LockOTPEmail serializes OTP operations for a normalized
// email address within a PostgreSQL transaction.
//
// The lock is automatically released when the
// transaction commits or rolls back.
func LockOTPEmail(
	ctx context.Context,
	tx pgx.Tx,
	normalizedEmail string,
) error {
	if normalizedEmail == "" {
		return fmt.Errorf("normalized email is required")
	}

	_, err := tx.Exec(ctx, `
		SELECT pg_advisory_xact_lock(
			hashtextextended($1, 0)
		)
	`, normalizedEmail)

	if err != nil {
		return fmt.Errorf("acquire OTP email lock: %w", err)
	}

	return nil
}
