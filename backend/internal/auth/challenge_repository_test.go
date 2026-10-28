package auth

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/database"
	"github.com/google/uuid"
)

func setupChallengeTest(t *testing.T) (
	*ChallengeRepository,
	[]byte,
) {
	t.Helper()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set; skipping PostgreSQL integration test")
	}

	ctx := context.Background()

	pool, err := database.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}

	return NewChallengeRepository(pool), secret
}

func createTestChallenge(
	t *testing.T,
	repo *ChallengeRepository,
	secret []byte,
	code string,
	expiresAt time.Time,
) uuid.UUID {
	t.Helper()

	id := uuid.New()

	hash, err := HashOTP(secret, id.String(), code)
	if err != nil {
		t.Fatal(err)
	}

	challenge := EmailChallenge{
		ID:              id,
		EmailNormalized: "test-" + id.String() + "@example.com",
		CodeHash:        hash,
		ExpiresAt:       expiresAt,
	}

	if err := repo.Create(
		context.Background(),
		challenge,
	); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM email_challenges WHERE id = $1",
			id,
		)
		if err != nil {
			t.Errorf("cleanup challenge: %v", err)
		}
	})

	return id
}

func TestChallengeCreateAndRetrieve(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	challenge, err := repo.GetByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}

	if challenge.ID != id {
		t.Fatal("retrieved wrong challenge")
	}

	if challenge.Attempts != 0 {
		t.Fatal("new challenge should have zero attempts")
	}
}

func TestChallengeVerifyAndConsume(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	err := repo.VerifyAndConsume(
		context.Background(), id, "123456", secret,
	)
	if err != nil {
		t.Fatal(err)
	}

	err = repo.VerifyAndConsume(
		context.Background(), id, "123456", secret,
	)
	if !errors.Is(err, ErrChallengeUsed) {
		t.Fatalf("expected consumed error, got %v", err)
	}
}

func TestChallengeWrongCodeIncrementsAttempts(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	err := repo.VerifyAndConsume(
		context.Background(), id, "999999", secret,
	)
	if !errors.Is(err, ErrInvalidOTP) {
		t.Fatalf("expected invalid OTP, got %v", err)
	}

	challenge, err := repo.GetByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}

	if challenge.Attempts != 1 {
		t.Fatalf("expected one attempt, got %d", challenge.Attempts)
	}
}

func TestChallengeExpired(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(-time.Minute),
	)

	err := repo.VerifyAndConsume(
		context.Background(), id, "123456", secret,
	)

	if !errors.Is(err, ErrChallengeExpired) {
		t.Fatalf("expected expired challenge, got %v", err)
	}
}

func TestChallengeLocksAfterMaxAttempts(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t, repo, secret, "123456",
		time.Now().Add(ChallengeLifetime),
	)

	for i := 0; i < MaxOTPAttempts; i++ {
		err := repo.VerifyAndConsume(
			context.Background(), id, "999999", secret,
		)
		if !errors.Is(err, ErrInvalidOTP) {
			t.Fatalf("attempt %d: %v", i+1, err)
		}
	}

	err := repo.VerifyAndConsume(
		context.Background(), id, "123456", secret,
	)
	if !errors.Is(err, ErrChallengeLocked) {
		t.Fatalf("expected locked challenge, got %v", err)
	}
}

func TestChallengeConcurrentVerification(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	id := createTestChallenge(
		t,
		repo,
		secret,
		"123456",
		time.Now().Add(ChallengeLifetime),
	)

	const workers = 10

	var wg sync.WaitGroup
	results := make(chan error, workers)

	start := make(chan struct{})

	for i := 0; i < workers; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			<-start

			err := repo.VerifyAndConsume(
				context.Background(),
				id,
				"123456",
				secret,
			)

			results <- err
		}()
	}

	close(start)

	wg.Wait()
	close(results)

	successCount := 0
	usedCount := 0

	for err := range results {
		switch {
		case err == nil:
			successCount++

		case errors.Is(err, ErrChallengeUsed):
			usedCount++

		default:
			t.Fatalf("unexpected verification error: %v", err)
		}
	}

	if successCount != 1 {
		t.Fatalf(
			"expected exactly one successful verification, got %d",
			successCount,
		)
	}

	if usedCount != workers-1 {
		t.Fatalf(
			"expected %d rejected reuses, got %d",
			workers-1,
			usedCount,
		)
	}
}
