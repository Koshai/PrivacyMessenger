package auth

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

const (
	ChallengeLifetime = 5 * time.Minute
	MaxOTPAttempts    = 5
)

var (
	ErrChallengeNotFound = errors.New("challenge not found")
	ErrChallengeExpired  = errors.New("challenge expired")
	ErrChallengeUsed     = errors.New("challenge already consumed")
	ErrChallengeLocked   = errors.New("challenge attempts exceeded")
	ErrInvalidOTP        = errors.New("invalid verification code")
)

type EmailChallenge struct {
	ID              uuid.UUID
	EmailNormalized string
	CodeHash        []byte
	ExpiresAt       time.Time
	ConsumedAt      *time.Time
	Attempts        int
	CreatedAt       time.Time
}
