package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
)

const SessionTokenBytes = 32

// GenerateSessionToken creates a cryptographically secure
// 256-bit bearer token suitable for authenticated sessions.
func GenerateSessionToken() (string, error) {
	randomBytes := make([]byte, SessionTokenBytes)

	if _, err := rand.Read(randomBytes); err != nil {
		return "", fmt.Errorf("generate session token: %w", err)
	}

	return base64.RawURLEncoding.EncodeToString(randomBytes), nil
}

// HashSessionToken returns the SHA-256 hash of a token.
// Only this hash should be persisted in PostgreSQL.
func HashSessionToken(token string) [32]byte {
	return sha256.Sum256([]byte(token))
}
