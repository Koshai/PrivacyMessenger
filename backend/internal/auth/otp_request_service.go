package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type OTPRequestService struct {
	issuer *OTPIssuer
	sender OTPSender
}

type OTPRequestResult struct {
	ChallengeID uuid.UUID
	ExpiresAt   time.Time
}

func NewOTPRequestService(
	issuer *OTPIssuer,
	sender OTPSender,
) (*OTPRequestService, error) {
	if issuer == nil || sender == nil {
		return nil, errors.New("issuer and sender required")
	}

	return &OTPRequestService{
		issuer: issuer,
		sender: sender,
	}, nil
}

// Request creates an OTP and sends it to the email address.
// The plaintext OTP is never returned to the caller.
func (s *OTPRequestService) Request(
	ctx context.Context,
	email string,
) (OTPRequestResult, error) {
	normalized, err := NormalizeEmail(email)
	if err != nil {
		return OTPRequestResult{}, err
	}

	issued, err := s.issuer.Issue(ctx, normalized)
	if err != nil {
		return OTPRequestResult{}, err
	}

	message := OTPMessage{
		Email:       normalized,
		ChallengeID: issued.ChallengeID.String(),
		Code:        issued.Code,
		ExpiresAt:   issued.ExpiresAt,
	}

	if err := s.sender.SendOTP(ctx, message); err != nil {
		// Use a fresh, bounded context for cleanup.
		// The request context may already be canceled.
		cleanupCtx, cancel := context.WithTimeout(
			context.Background(),
			5*time.Second,
		)
		defer cancel()

		if cleanupErr := s.issuer.InvalidateChallenge(
			cleanupCtx,
			issued.ChallengeID,
		); cleanupErr != nil {
			return OTPRequestResult{}, errors.Join(
				fmt.Errorf("deliver OTP: %w", err),
				fmt.Errorf(
					"cleanup failed OTP: %w",
					cleanupErr,
				),
			)
		}

		return OTPRequestResult{},
			fmt.Errorf("deliver OTP: %w", err)
	}

	if err := s.issuer.ActivateChallenge(
		ctx,
		issued.ChallengeID,
	); err != nil {
		return OTPRequestResult{},
			fmt.Errorf("activate delivered OTP: %w", err)
	}

	return OTPRequestResult{
		ChallengeID: issued.ChallengeID,
		ExpiresAt:   issued.ExpiresAt,
	}, nil
}
