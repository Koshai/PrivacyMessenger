package auth

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"
)

func TestOTPRequestServiceDeliversCode(t *testing.T) {
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

	sender := NewMemoryOTPSender()

	service, err := NewOTPRequestService(issuer, sender)
	if err != nil {
		t.Fatal(err)
	}

	email := fmt.Sprintf(
		"delivery-%s@example.com", uuid.NewString(),
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

	result, err := service.Request(ctx, email)
	if err != nil {
		t.Fatal(err)
	}

	messages := sender.Messages()
	if len(messages) != 1 {
		t.Fatalf("expected 1 message, got %d", len(messages))
	}

	if messages[0].Email != email {
		t.Fatal("incorrect delivery address")
	}

	if messages[0].ChallengeID != result.ChallengeID.String() {
		t.Fatal("challenge ID mismatch")
	}

	challenge, err := repo.GetByID(ctx, result.ChallengeID)
	if err != nil {
		t.Fatal(err)
	}

	if !VerifyOTPHash(
		secret,
		result.ChallengeID.String(),
		messages[0].Code,
		challenge.CodeHash,
	) {
		t.Fatal("delivered OTP does not match stored hash")
	}
}

func TestOTPRequestServiceRejectsInvalidEmail(t *testing.T) {
	repo, secret := setupChallengeTest(t)

	issuer, err := NewOTPIssuer(
		repo.db,
		secret,
		NewOTPRateLimiter(repo.db),
	)
	if err != nil {
		t.Fatal(err)
	}

	sender := NewMemoryOTPSender()
	service, err := NewOTPRequestService(issuer, sender)
	if err != nil {
		t.Fatal(err)
	}

	_, err = service.Request(
		context.Background(),
		"not-an-email",
	)

	if err == nil {
		t.Fatal("expected invalid email rejection")
	}

	if len(sender.Messages()) != 0 {
		t.Fatal("invalid email should not trigger delivery")
	}
}
