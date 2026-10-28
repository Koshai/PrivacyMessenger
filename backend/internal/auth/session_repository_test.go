package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSessionRepositoryRejectsInvalidToken(t *testing.T) {
	repo, _ := setupChallengeTest(t)

	sessions := NewSessionRepository(repo.db)

	tests := []string{
		"",
		"invalid",
		"not-a-session-token",
	}

	for _, token := range tests {
		_, err := sessions.Authenticate(
			context.Background(),
			token,
		)

		if !errors.Is(err, ErrInvalidSession) {
			t.Fatalf(
				"expected ErrInvalidSession for %q, got %v",
				token,
				err,
			)
		}
	}
}

func TestSessionRepositoryAuthenticatesValidSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "session-" + uuid.NewString() + "@example.com"

	t.Cleanup(func() {
		_, _ = repo.db.Exec(ctx, `
			DELETE FROM sessions
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)
		_, _ = repo.db.Exec(ctx, `
			DELETE FROM devices
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)
		_, _ = repo.db.Exec(
			ctx,
			"DELETE FROM users WHERE email_normalized = $1",
			email,
		)
		_, _ = repo.db.Exec(
			ctx,
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

	challenge := EmailChallenge{
		ID:              challengeID,
		EmailNormalized: email,
		CodeHash:        hash,
		ExpiresAt:       time.Now().Add(ChallengeLifetime),
	}

	if err := repo.Create(ctx, challenge); err != nil {
		t.Fatal(err)
	}

	loginService, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	login, err := loginService.VerifyAndLogin(
		ctx,
		challengeID,
		code,
		"Test Device",
	)
	if err != nil {
		t.Fatal(err)
	}

	sessions := NewSessionRepository(repo.db)

	authenticated, err := sessions.Authenticate(
		ctx,
		login.Token,
	)
	if err != nil {
		t.Fatal(err)
	}

	if authenticated.UserID != login.UserID {
		t.Fatal("user ID mismatch")
	}

	if authenticated.DeviceID != login.DeviceID {
		t.Fatal("device ID mismatch")
	}

	// Verify revocation immediately invalidates the token.
	_, err = repo.db.Exec(ctx, `
		UPDATE sessions
		SET revoked_at = NOW()
		WHERE user_id = $1
		  AND device_id = $2
	`, login.UserID, login.DeviceID)
	if err != nil {
		t.Fatal(err)
	}

	_, err = sessions.Authenticate(ctx, login.Token)
	if !errors.Is(err, ErrInvalidSession) {
		t.Fatalf("expected revoked session rejection, got %v", err)
	}
}

func TestSessionRepositoryRejectsExpiredSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "expired-" + uuid.NewString() + "@example.com"

	// Reuse the existing OTP and login flow to create
	// a genuine session.
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

	t.Cleanup(func() {
		cleanupCtx := context.Background()

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM sessions WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM devices WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(cleanupCtx,
			"DELETE FROM users WHERE email_normalized = $1", email)
		_, _ = repo.db.Exec(cleanupCtx,
			"DELETE FROM email_challenges WHERE email_normalized = $1", email)
	})

	loginService, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	login, err := loginService.VerifyAndLogin(
		ctx, challengeID, code, "Expired Session Test",
	)
	if err != nil {
		t.Fatal(err)
	}

	// Force the session into the past.
	_, err = repo.db.Exec(ctx, `
		UPDATE sessions
		SET expires_at = NOW() - INTERVAL '1 minute'
		WHERE user_id = $1 AND device_id = $2
	`, login.UserID, login.DeviceID)
	if err != nil {
		t.Fatal(err)
	}

	sessions := NewSessionRepository(repo.db)

	_, err = sessions.Authenticate(ctx, login.Token)

	if !errors.Is(err, ErrInvalidSession) {
		t.Fatalf(
			"expected expired session rejection, got %v",
			err,
		)
	}
}

func TestSessionRepositoryRejectsDeletedUser(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "deleted-" + uuid.NewString() + "@example.com"

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

	t.Cleanup(func() {
		cleanupCtx := context.Background()

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM sessions WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(cleanupCtx, `
			DELETE FROM devices WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = repo.db.Exec(cleanupCtx,
			"DELETE FROM users WHERE email_normalized = $1", email)
		_, _ = repo.db.Exec(cleanupCtx,
			"DELETE FROM email_challenges WHERE email_normalized = $1", email)
	})

	loginService, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	login, err := loginService.VerifyAndLogin(
		ctx, challengeID, code, "Deleted User Test",
	)
	if err != nil {
		t.Fatal(err)
	}

	// Soft-delete the account without revoking the session.
	// Authentication must still reject it.
	_, err = repo.db.Exec(ctx, `
		UPDATE users
		SET deleted_at = NOW()
		WHERE id = $1
	`, login.UserID)
	if err != nil {
		t.Fatal(err)
	}

	sessions := NewSessionRepository(repo.db)

	_, err = sessions.Authenticate(ctx, login.Token)

	if !errors.Is(err, ErrInvalidSession) {
		t.Fatalf(
			"expected deleted-user rejection, got %v",
			err,
		)
	}
}
