package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const OTPDigits = 6

// GenerateOTP creates a cryptographically random six-digit code.
func GenerateOTP() (string, error) {
	var data [4]byte

	if _, err := rand.Read(data[:]); err != nil {
		return "", fmt.Errorf("generate OTP: %w", err)
	}

	value := binary.BigEndian.Uint32(data[:])

	// Rejection sampling avoids modulo bias.
	const rangeSize = uint64(1_000_000)
	const maxValue = uint64(1) << 32
	const limit = maxValue - (maxValue % rangeSize)

	for uint64(value) >= limit {
		if _, err := rand.Read(data[:]); err != nil {
			return "", fmt.Errorf("generate OTP: %w", err)
		}
		value = binary.BigEndian.Uint32(data[:])
	}

	return fmt.Sprintf("%06d", uint64(value)%rangeSize), nil
}

// HashOTP protects a low-entropy OTP using a secret server key.
// The challenge ID binds the hash to one verification attempt.
func HashOTP(
	secret []byte,
	challengeID string,
	code string,
) ([]byte, error) {
	if len(secret) < 32 {
		return nil, errors.New("OTP secret must be at least 32 bytes")
	}

	if challengeID == "" || len(code) != OTPDigits {
		return nil, errors.New("invalid OTP input")
	}

	for _, digit := range code {
		if digit < '0' || digit > '9' {
			return nil, errors.New("OTP must contain only digits")
		}
	}

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(challengeID))
	mac.Write([]byte{0})
	mac.Write([]byte(code))

	return mac.Sum(nil), nil
}

func VerifyOTPHash(
	secret []byte,
	challengeID string,
	code string,
	expectedHash []byte,
) bool {
	actual, err := HashOTP(secret, challengeID, code)
	if err != nil {
		return false
	}

	return hmac.Equal(actual, expectedHash)
}
