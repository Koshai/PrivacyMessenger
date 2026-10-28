package auth

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestLoginCreatesUserAndSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	result, err := service.VerifyAndLogin(
		context.Background(),
		id,
		"123456",
		"Android Test Device",
	)
	if err != nil {
		t.Fatal(err)
	}

	if result.UserID == uuid.Nil ||
		result.DeviceID == uuid.Nil ||
		result.Token == "" {
		t.Fatal("incomplete login result")
	}

	tokenHash := HashSessionToken(result.Token)

	var count int
	err = repo.db.QueryRow(
		context.Background(),
		`SELECT COUNT(*) FROM sessions
		 WHERE user_id = $1 AND token_hash = $2
		   AND revoked_at IS NULL`,
		result.UserID,
		tokenHash[:],
	).Scan(&count)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatal("expected one active session")
	}

	t.Cleanup(func() {
		ctx := context.Background()
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM sessions WHERE user_id = $1",
			result.UserID)
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM devices WHERE user_id = $1",
			result.UserID)
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM users WHERE id = $1",
			result.UserID)
	})
}

func TestLoginRejectsOTPReuse(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	result, err := service.VerifyAndLogin(
		context.Background(), id, "123456", "Android",
	)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		ctx := context.Background()
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM sessions WHERE user_id = $1",
			result.UserID)
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM devices WHERE user_id = $1",
			result.UserID)
		_, _ = repo.db.Exec(ctx,
			"DELETE FROM users WHERE id = $1",
			result.UserID)
	})

	_, err = service.VerifyAndLogin(
		context.Background(), id, "123456", "Other Device",
	)
	if !errors.Is(err, ErrChallengeUsed) {
		t.Fatalf("expected OTP reuse rejection, got %v", err)
	}
}

func TestLoginWrongOTPDoesNotCreateUser(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	_, err = service.VerifyAndLogin(
		context.Background(), id, "999999", "Android",
	)
	if !errors.Is(err, ErrInvalidOTP) {
		t.Fatalf("expected invalid OTP, got %v", err)
	}

	challenge, err := repo.GetByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	if challenge.Attempts != 1 || challenge.ConsumedAt != nil {
		t.Fatal("incorrect OTP modified challenge unexpectedly")
	}

	var count int
	err = repo.db.QueryRow(context.Background(), `
		SELECT COUNT(*) FROM users
		WHERE email_normalized = $1
	`, challenge.EmailNormalized).Scan(&count)
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("wrong OTP created an account")
	}
}

func TestLoginReplacesPreviousDeviceSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	// First login.
	firstChallengeID := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	first, err := service.VerifyAndLogin(
		ctx, firstChallengeID, "123456", "Android Phone",
	)
	if err != nil {
		t.Fatal(err)
	}

	// Register cleanup immediately so later failures
	// do not leave the account and sessions behind.
	t.Cleanup(func() {
		cleanupCtx := context.Background()

		for _, query := range []string{
			"DELETE FROM sessions WHERE user_id = $1",
			"DELETE FROM devices WHERE user_id = $1",
			"DELETE FROM users WHERE id = $1",
		} {
			if _, err := repo.db.Exec(
				cleanupCtx, query, first.UserID,
			); err != nil {
				t.Errorf("cleanup: %v", err)
			}
		}
	})

	// Create another OTP for the same email.
	secondChallengeID := uuid.New()

	hash, err := HashOTP(
		secret, secondChallengeID.String(), "654321",
	)
	if err != nil {
		t.Fatal(err)
	}

	_, err = repo.db.Exec(ctx, `
		INSERT INTO email_challenges
			(id, email_normalized, code_hash, expires_at)
		SELECT $1, email_normalized, $2, $3
		FROM users
		WHERE id = $4
	`,
		secondChallengeID,
		hash,
		time.Now().Add(ChallengeLifetime),
		first.UserID,
	)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM email_challenges WHERE id = $1",
			secondChallengeID,
		)
		if err != nil {
			t.Errorf("cleanup challenge: %v", err)
		}
	})

	// Sign in from a second device.
	second, err := service.VerifyAndLogin(
		ctx, secondChallengeID, "654321", "iPhone",
	)
	if err != nil {
		t.Fatal(err)
	}

	if first.UserID != second.UserID {
		t.Fatal("same email must resolve to same user")
	}

	if first.DeviceID == second.DeviceID {
		t.Fatal("new login should register a new device")
	}

	firstHash := HashSessionToken(first.Token)
	secondHash := HashSessionToken(second.Token)

	var firstRevoked bool
	err = repo.db.QueryRow(ctx, `
		SELECT revoked_at IS NOT NULL
		FROM sessions WHERE token_hash = $1
	`, firstHash[:]).Scan(&firstRevoked)
	if err != nil {
		t.Fatal(err)
	}

	if !firstRevoked {
		t.Fatal("first device session was not revoked")
	}

	var activeCount int
	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM sessions
		WHERE user_id = $1
		  AND token_hash = $2
		  AND revoked_at IS NULL
		  AND expires_at > NOW()
	`, second.UserID, secondHash[:]).Scan(&activeCount)
	if err != nil {
		t.Fatal(err)
	}

	if activeCount != 1 {
		t.Fatal("second device session is not active")
	}
}

func TestConcurrentLoginsAllowOneActiveSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	// Create one account using a successful login.
	firstChallenge := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	initial, err := service.VerifyAndLogin(
		ctx, firstChallenge, "123456", "Initial Phone",
	)
	if err != nil {
		t.Fatal(err)
	}

	// Register cleanup before performing more assertions.
	t.Cleanup(func() {
		cleanupCtx := context.Background()

		for _, query := range []string{
			"DELETE FROM sessions WHERE user_id = $1",
			"DELETE FROM devices WHERE user_id = $1",
			"DELETE FROM users WHERE id = $1",
		} {
			if _, err := repo.db.Exec(
				cleanupCtx, query, initial.UserID,
			); err != nil {
				t.Errorf("cleanup: %v", err)
			}
		}
	})

	// Two valid OTP challenges for the same account.
	challengeIDs := []uuid.UUID{
		uuid.New(),
		uuid.New(),
	}

	for _, id := range challengeIDs {
		hash, err := HashOTP(secret, id.String(), "654321")
		if err != nil {
			t.Fatal(err)
		}

		err = repo.Create(ctx, EmailChallenge{
			ID: id,
			EmailNormalized: func() string {
				var email string
				if err := repo.db.QueryRow(
					ctx,
					"SELECT email_normalized FROM users WHERE id = $1",
					initial.UserID,
				).Scan(&email); err != nil {
					t.Fatal(err)
				}
				return email
			}(),
			CodeHash:  hash,
			ExpiresAt: time.Now().Add(ChallengeLifetime),
		})
		if err != nil {
			t.Fatal(err)
		}

		challengeID := id
		t.Cleanup(func() {
			_, err := repo.db.Exec(
				context.Background(),
				"DELETE FROM email_challenges WHERE id = $1",
				challengeID,
			)
			if err != nil {
				t.Errorf("cleanup challenge: %v", err)
			}
		})
	}

	var wg sync.WaitGroup
	start := make(chan struct{})

	results := make(chan LoginResult, 2)
	errs := make(chan error, 2)

	for i, id := range challengeIDs {
		wg.Add(1)

		go func(id uuid.UUID, device string) {
			defer wg.Done()
			<-start

			result, err := service.VerifyAndLogin(
				ctx, id, "654321", device,
			)
			if err != nil {
				errs <- err
				return
			}
			results <- result
		}(id, []string{"Android", "iPhone"}[i])
	}

	close(start)
	wg.Wait()

	close(results)
	close(errs)

	for err := range errs {
		t.Errorf("concurrent login failed: %v", err)
	}
	if t.Failed() {
		return
	}

	var completed []LoginResult
	for result := range results {
		completed = append(completed, result)
	}

	if len(completed) != 2 {
		t.Fatalf(
			"expected 2 completed logins, got %d",
			len(completed),
		)
	}

	for _, result := range completed {
		if result.UserID != initial.UserID {
			t.Fatal("login resolved to unexpected account")
		}
	}

	var activeCount int
	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM sessions
		WHERE user_id = $1
		  AND revoked_at IS NULL
		  AND expires_at > NOW()
	`, initial.UserID).Scan(&activeCount)
	if err != nil {
		t.Fatal(err)
	}

	if activeCount != 1 {
		t.Fatalf(
			"expected exactly 1 active session, got %d",
			activeCount,
		)
	}
}

func TestLoginRollbackPreservesPreviousSession(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	service, err := NewLoginService(repo.db, secret)
	if err != nil {
		t.Fatal(err)
	}

	// Establish an existing authenticated session.
	firstChallenge := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	first, err := service.VerifyAndLogin(
		ctx, firstChallenge, "123456", "Android",
	)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		cleanupCtx := context.Background()

		for _, query := range []string{
			"DELETE FROM sessions WHERE user_id = $1",
			"DELETE FROM devices WHERE user_id = $1",
			"DELETE FROM users WHERE id = $1",
		} {
			if _, err := repo.db.Exec(
				cleanupCtx, query, first.UserID,
			); err != nil {
				t.Errorf("cleanup: %v", err)
			}
		}
	})

	// Prepare another challenge for the same account.
	secondID := uuid.New()
	hash, err := HashOTP(
		secret, secondID.String(), "654321",
	)
	if err != nil {
		t.Fatal(err)
	}

	var email string
	err = repo.db.QueryRow(ctx,
		"SELECT email_normalized FROM users WHERE id = $1",
		first.UserID,
	).Scan(&email)
	if err != nil {
		t.Fatal(err)
	}

	err = repo.Create(ctx, EmailChallenge{
		ID:              secondID,
		EmailNormalized: email,
		CodeHash:        hash,
		ExpiresAt:       time.Now().Add(ChallengeLifetime),
	})
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM email_challenges WHERE id = $1",
			secondID,
		)
		if err != nil {
			t.Errorf("cleanup challenge: %v", err)
		}
	})

	// Simulate a failure after revoking old sessions
	// but before creating the replacement session.
	injectedErr := errors.New("simulated session failure")
	service.beforeSessionInsert = func() error {
		return injectedErr
	}

	_, err = service.VerifyAndLogin(
		ctx, secondID, "654321", "iPhone",
	)
	if !errors.Is(err, injectedErr) {
		t.Fatalf("expected injected failure, got %v", err)
	}

	// The original session must still be active.
	firstHash := HashSessionToken(first.Token)

	var activeCount int
	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM sessions
		WHERE user_id = $1
		  AND token_hash = $2
		  AND revoked_at IS NULL
		  AND expires_at > NOW()
	`, first.UserID, firstHash[:]).Scan(&activeCount)
	if err != nil {
		t.Fatal(err)
	}

	if activeCount != 1 {
		t.Fatal("rollback failed to preserve original session")
	}

	// The second OTP must remain unconsumed.
	challenge, err := repo.GetByID(ctx, secondID)
	if err != nil {
		t.Fatal(err)
	}

	if challenge.ConsumedAt != nil {
		t.Fatal("rollback failed: OTP was consumed")
	}

	// The failed login must not leave another device.
	var deviceCount int
	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*) FROM devices WHERE user_id = $1
	`, first.UserID).Scan(&deviceCount)
	if err != nil {
		t.Fatal(err)
	}

	if deviceCount != 1 {
		t.Fatalf(
			"expected 1 device after rollback, got %d",
			deviceCount,
		)
	}

	// Remove the injected failure and retry the OTP.
	service.beforeSessionInsert = nil

	second, err := service.VerifyAndLogin(
		ctx, secondID, "654321", "iPhone",
	)
	if err != nil {
		t.Fatalf("retry after rollback failed: %v", err)
	}

	if second.UserID != first.UserID {
		t.Fatal("retry returned unexpected user")
	}
}

func TestLoginRejectsDeletedAccount(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "deleted-login-" + uuid.NewString() + "@example.com"

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

	// Create a soft-deleted account.
	userID := uuid.New()

	_, err := repo.db.Exec(ctx, `
		INSERT INTO users (
			id, email, email_normalized, deleted_at
		)
		VALUES ($1, $2, $2, NOW())
	`, userID, email)
	if err != nil {
		t.Fatal(err)
	}

	// Create a legitimate OTP challenge.
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

	// A valid OTP must not bypass account deletion.
	_, err = loginService.VerifyAndLogin(
		ctx,
		challengeID,
		code,
		"Deleted Account Test Device",
	)

	if !errors.Is(err, ErrAccountDeleted) {
		t.Fatalf(
			"expected ErrAccountDeleted, got %v",
			err,
		)
	}

	// Confirm no device was created.
	var deviceCount int

	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM devices
		WHERE user_id = $1
	`, userID).Scan(&deviceCount)
	if err != nil {
		t.Fatal(err)
	}

	if deviceCount != 0 {
		t.Fatalf(
			"expected zero devices, got %d",
			deviceCount,
		)
	}

	// Confirm no session was created.
	var sessionCount int

	err = repo.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM sessions
		WHERE user_id = $1
	`, userID).Scan(&sessionCount)
	if err != nil {
		t.Fatal(err)
	}

	if sessionCount != 0 {
		t.Fatalf(
			"expected zero sessions, got %d",
			sessionCount,
		)
	}

	// Confirm account remains deleted.
	var stillDeleted bool

	err = repo.db.QueryRow(ctx, `
		SELECT deleted_at IS NOT NULL
		FROM users
		WHERE id = $1
	`, userID).Scan(&stillDeleted)
	if err != nil {
		t.Fatal(err)
	}

	if !stillDeleted {
		t.Fatal("deleted account was reactivated")
	}

	// Confirm the failed login did not consume the OTP.
	var consumed bool

	err = repo.db.QueryRow(ctx, `
		SELECT consumed_at IS NOT NULL
		FROM email_challenges
		WHERE id = $1
	`, challengeID).Scan(&consumed)
	if err != nil {
		t.Fatal(err)
	}

	if consumed {
		t.Fatal("failed login consumed the OTP")
	}
}
