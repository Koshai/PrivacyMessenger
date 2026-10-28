package auth

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

type failingOTPSender struct {
	err error
}

func (s failingOTPSender) SendOTP(
	ctx context.Context,
	message OTPMessage,
) error {
	return s.err
}

func TestOTPRequestServiceRejectsMissingDependencies(
	t *testing.T,
) {
	_, err := NewOTPRequestService(nil, failingOTPSender{
		err: errors.New("delivery failed"),
	})

	if err == nil {
		t.Fatal("expected constructor error")
	}
}

func TestInvalidateChallengeRejectsNilID(t *testing.T) {
	issuer := &OTPIssuer{}

	err := issuer.InvalidateChallenge(
		context.Background(),
		uuid.Nil,
	)

	if err == nil {
		t.Fatal("expected error for nil challenge ID")
	}
}

func TestOTPDeliveryFailureInvalidatesChallenge(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	email := "delivery-failure-" +
		uuid.NewString() + "@example.com"

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

	issuer, err := NewOTPIssuer(
		repo.db,
		secret,
		limiter,
	)
	if err != nil {
		t.Fatal(err)
	}

	service, err := NewOTPRequestService(
		issuer,
		failingOTPSender{
			err: errors.New("simulated delivery failure"),
		},
	)
	if err != nil {
		t.Fatal(err)
	}

	_, err = service.Request(ctx, email)

	if err == nil {
		t.Fatal("expected delivery failure")
	}

	var totalChallenges int
	var activeChallenges int

	err = repo.db.QueryRow(ctx, `
		SELECT
			COUNT(*),
			COUNT(*) FILTER (
				WHERE consumed_at IS NULL
			)
		FROM email_challenges
		WHERE email_normalized = $1
	`, email).Scan(
		&totalChallenges,
		&activeChallenges,
	)
	if err != nil {
		t.Fatal(err)
	}

	if totalChallenges != 1 {
		t.Fatalf(
			"expected one challenge, got %d",
			totalChallenges,
		)
	}

	if activeChallenges != 0 {
		t.Fatalf(
			"expected zero active challenges, got %d",
			activeChallenges,
		)
	}
}
