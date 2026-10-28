package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestLoginWaitsForOTPEmailLock(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "otp-lock-" + uuid.NewString() + "@example.com"

	t.Cleanup(func() {
		cleanupCtx := context.Background()

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM sessions
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM devices
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(
			cleanupCtx,
			"DELETE FROM users WHERE email_normalized = $1",
			email,
		)

		_, _ = repo.db.Exec(
			cleanupCtx,
			"DELETE FROM email_challenges WHERE email_normalized = $1",
			email,
		)
	})

	code, err := GenerateOTP()
	if err != nil {
		t.Fatal(err)
	}

	challengeID := uuid.New()

	hash, err := HashOTP(
		secret,
		challengeID.String(),
		code,
	)
	if err != nil {
		t.Fatal(err)
	}

	err = repo.Create(ctx, EmailChallenge{
		ID:              challengeID,
		EmailNormalized: email,
		CodeHash:        hash,
		ExpiresAt:       time.Now().Add(ChallengeLifetime),
	})
	if err != nil {
		t.Fatal(err)
	}

	loginService, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	// Hold the email-level advisory lock in one transaction.
	lockTx, err := repo.db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer lockTx.Rollback(ctx)

	if err := LockOTPEmail(ctx, lockTx, email); err != nil {
		t.Fatal(err)
	}

	// Start login with a short deadline. Because the lock
	// is held, login must not complete successfully.
	loginCtx, cancel := context.WithTimeout(
		ctx,
		150*time.Millisecond,
	)
	defer cancel()

	_, err = loginService.VerifyAndLogin(
		loginCtx,
		challengeID,
		code,
		"Concurrent Test Device",
	)

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf(
			"expected login to wait for lock until deadline, got %v",
			err,
		)
	}

	// Release the advisory lock.
	if err := lockTx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	// The same OTP should now be usable because the
	// timed-out login transaction was rolled back.
	result, err := loginService.VerifyAndLogin(
		ctx,
		challengeID,
		code,
		"Concurrent Test Device",
	)

	if err != nil {
		t.Fatalf(
			"login should succeed after lock release: %v",
			err,
		)
	}

	if result.Token == "" {
		t.Fatal("expected a session token")
	}
}
