package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestLoginRejectsPendingAndFailedOTP(t *testing.T) {
	repo, secret := setupChallengeTest(t)
	ctx := context.Background()

	for _, status := range []string{"PENDING", "FAILED"} {
		t.Run(status, func(t *testing.T) {
			email := "otp-state-" +
				uuid.NewString() + "@example.com"

			challengeID := uuid.New()

			code, err := GenerateOTP()
			if err != nil {
				t.Fatal(err)
			}

			hash, err := HashOTP(
				secret,
				challengeID.String(),
				code,
			)
			if err != nil {
				t.Fatal(err)
			}

			_, err = repo.db.Exec(ctx, `
				INSERT INTO email_challenges (
					id,
					email_normalized,
					code_hash,
					expires_at,
					delivery_status
				)
				VALUES ($1, $2, $3, $4, $5)
			`,
				challengeID,
				email,
				hash,
				time.Now().Add(ChallengeLifetime),
				status,
			)
			if err != nil {
				t.Fatal(err)
			}

			t.Cleanup(func() {
				_, _ = repo.db.Exec(
					context.Background(),
					"DELETE FROM email_challenges WHERE id = $1",
					challengeID,
				)
			})

			service, err := NewLoginService(
				repo.db,
				secret,
			)
			if err != nil {
				t.Fatal(err)
			}

			_, err = service.VerifyAndLogin(
				ctx,
				challengeID,
				code,
				"Security Test Device",
			)

			if !errors.Is(err, ErrChallengeNotActive) {
				t.Fatalf(
					"expected ErrChallengeNotActive, got %v",
					err,
				)
			}
		})
	}
}
