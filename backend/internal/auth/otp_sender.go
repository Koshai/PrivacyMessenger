package auth

import (
	"context"
	"errors"
	"sync"
	"time"
)

type OTPMessage struct {
	Email       string
	ChallengeID string
	Code        string
	ExpiresAt   time.Time
}

type OTPSender interface {
	SendOTP(ctx context.Context, message OTPMessage) error
}

// MemoryOTPSender is for local development and tests only.
// Never register it as a production email transport.
type MemoryOTPSender struct {
	mu       sync.Mutex
	messages []OTPMessage
}

func NewMemoryOTPSender() *MemoryOTPSender {
	return &MemoryOTPSender{}
}

func (s *MemoryOTPSender) SendOTP(
	ctx context.Context,
	message OTPMessage,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	if message.Email == "" ||
		message.ChallengeID == "" ||
		message.Code == "" {
		return errors.New("incomplete OTP message")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.messages = append(s.messages, message)
	return nil
}

// Messages returns a snapshot for tests.
// It must never be exposed through an HTTP endpoint.
func (s *MemoryOTPSender) Messages() []OTPMessage {
	s.mu.Lock()
	defer s.mu.Unlock()

	result := make([]OTPMessage, len(s.messages))
	copy(result, s.messages)
	return result
}
