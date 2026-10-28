package auth

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestOTPRateLimiter(t *testing.T) {
	repo, _ := setupChallengeTest(t)
	ctx := context.Background()

	limiter := NewOTPRateLimiter(repo.db)
	email := fmt.Sprintf(
		"rate-limit-%s@example.com", uuid.NewString(),
	)

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
		if err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})

	for i := 0; i < MaxOTPRequests; i++ {
		if err := limiter.AllowRequest(ctx, email); err != nil {
			t.Fatalf("request %d unexpectedly rejected: %v", i+1, err)
		}
	}

	if err := limiter.AllowRequest(ctx, email); !errors.Is(err, ErrOTPRateLimited) {
		t.Fatalf("expected rate limit rejection, got %v", err)
	}
}

func TestOTPRateLimiterResetsExpiredWindow(t *testing.T) {
	repo, _ := setupChallengeTest(t)
	ctx := context.Background()

	limiter := NewOTPRateLimiter(repo.db)
	email := fmt.Sprintf(
		"rate-reset-%s@example.com", uuid.NewString(),
	)

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
		if err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})

	_, err := repo.db.Exec(ctx, `
		INSERT INTO otp_request_limits
			(email_normalized, window_started_at, request_count)
		VALUES ($1, $2, $3)
	`, email, time.Now().Add(-OTPRequestWindow-time.Minute), MaxOTPRequests)
	if err != nil {
		t.Fatal(err)
	}

	if err := limiter.AllowRequest(ctx, email); err != nil {
		t.Fatalf("expired window should reset: %v", err)
	}

	var count int
	err = repo.db.QueryRow(ctx, `
		SELECT request_count FROM otp_request_limits
		WHERE email_normalized = $1
	`, email).Scan(&count)
	if err != nil {
		t.Fatal(err)
	}

	if count != 1 {
		t.Fatalf("expected reset count 1, got %d", count)
	}
}

func TestOTPRateLimiterConcurrentRequests(t *testing.T) {
	repo, _ := setupChallengeTest(t)
	ctx := context.Background()

	limiter := NewOTPRateLimiter(repo.db)
	email := fmt.Sprintf(
		"rate-concurrent-%s@example.com",
		uuid.NewString(),
	)

	t.Cleanup(func() {
		_, err := repo.db.Exec(
			context.Background(),
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
		if err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})

	const workers = 10

	var wg sync.WaitGroup
	start := make(chan struct{})
	results := make(chan error, workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()
			<-start

			results <- limiter.AllowRequest(ctx, email)
		}()
	}

	close(start)
	wg.Wait()
	close(results)

	allowed := 0
	rejected := 0

	for err := range results {
		switch {
		case err == nil:
			allowed++

		case errors.Is(err, ErrOTPRateLimited):
			rejected++

		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}

	if allowed != MaxOTPRequests {
		t.Fatalf(
			"expected %d allowed, got %d",
			MaxOTPRequests,
			allowed,
		)
	}

	if rejected != workers-MaxOTPRequests {
		t.Fatalf(
			"expected %d rejected, got %d",
			workers-MaxOTPRequests,
			rejected,
		)
	}

	var storedCount int

	err := repo.db.QueryRow(ctx, `
		SELECT request_count
		FROM otp_request_limits
		WHERE email_normalized = $1
	`, email).Scan(&storedCount)

	if err != nil {
		t.Fatal(err)
	}

	if storedCount != workers {
		t.Fatalf(
			"expected %d recorded attempts, got %d",
			workers,
			storedCount,
		)
	}
}
