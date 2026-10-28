package auth

import (
	"context"
	"testing"

	"github.com/google/uuid"
)

func TestReplacedOTPCannotBeActivated(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "replacement-" + uuid.NewString() + "@example.com"

	t.Cleanup(func() {
		_, _ = repo.db.Exec(
			context.Background(),
			"DELETE FROM email_challenges WHERE email_normalized = $1",
			email,
		)
		_, _ = repo.db.Exec(
			context.Background(),
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
	})

	limiter := NewOTPRateLimiter(repo.db)

	issuer, err := NewOTPIssuer(repo.db, secret, limiter)
	if err != nil {
		t.Fatal(err)
	}

	first, err := issuer.Issue(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	second, err := issuer.Issue(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	// The first challenge was replaced and must not
	// become active, even if delivery later succeeds.
	if err := issuer.ActivateChallenge(
		ctx,
		first.ChallengeID,
	); err == nil {
		t.Fatal("replaced challenge was activated")
	}

	// The latest challenge can still be activated.
	if err := issuer.ActivateChallenge(
		ctx,
		second.ChallengeID,
	); err != nil {
		t.Fatalf("activate latest challenge: %v", err)
	}

	var firstStatus string
	var firstConsumed bool

	err = repo.db.QueryRow(ctx, `
		SELECT delivery_status, consumed_at IS NOT NULL
		FROM email_challenges
		WHERE id = $1
	`, first.ChallengeID).Scan(
		&firstStatus,
		&firstConsumed,
	)
	if err != nil {
		t.Fatal(err)
	}

	if firstStatus == "ACTIVE" || !firstConsumed {
		t.Fatal("replaced challenge remains usable")
	}

	var secondStatus string

	err = repo.db.QueryRow(ctx, `
		SELECT delivery_status
		FROM email_challenges
		WHERE id = $1
	`, second.ChallengeID).Scan(&secondStatus)
	if err != nil {
		t.Fatal(err)
	}

	if secondStatus != "ACTIVE" {
		t.Fatalf(
			"expected ACTIVE, got %s",
			secondStatus,
		)
	}
}
