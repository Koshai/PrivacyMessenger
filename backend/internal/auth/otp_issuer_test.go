package auth

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/google/uuid"
)

func TestOTPIssuerCreatesChallenge(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	issuer, err := NewOTPIssuer(
		repo.db,
		secret,
		NewOTPRateLimiter(repo.db),
	)
	if err != nil {
		t.Fatal(err)
	}

	email := fmt.Sprintf(
		"issue-%s@example.com", uuid.NewString(),
	)

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

	issued, err := issuer.Issue(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	if issued.ChallengeID == uuid.Nil || len(issued.Code) != 6 {
		t.Fatal("invalid issued OTP")
	}

	challenge, err := repo.GetByID(ctx, issued.ChallengeID)
	if err != nil {
		t.Fatal(err)
	}

	if !VerifyOTPHash(
		secret,
		issued.ChallengeID.String(),
		issued.Code,
		challenge.CodeHash,
	) {
		t.Fatal("stored hash does not match issued OTP")
	}
}

func TestOTPIssuerInvalidatesPreviousChallenge(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	issuer, err := NewOTPIssuer(
		repo.db,
		secret,
		NewOTPRateLimiter(repo.db),
	)
	if err != nil {
		t.Fatal(err)
	}

	email := fmt.Sprintf(
		"replace-%s@example.com", uuid.NewString(),
	)

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

	first, err := issuer.Issue(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	second, err := issuer.Issue(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	firstChallenge, err := repo.GetByID(ctx, first.ChallengeID)
	if err != nil {
		t.Fatal(err)
	}

	if firstChallenge.ConsumedAt == nil {
		t.Fatal("previous challenge remains valid")
	}

	secondChallenge, err := repo.GetByID(ctx, second.ChallengeID)
	if err != nil {
		t.Fatal(err)
	}

	if secondChallenge.ConsumedAt != nil {
		t.Fatal("new challenge was unexpectedly consumed")
	}

	err = repo.VerifyAndConsume(
		ctx, first.ChallengeID, first.Code, secret,
	)
	if !errors.Is(err, ErrChallengeUsed) {
		t.Fatalf("expected old OTP rejection, got %v", err)
	}
}
