package auth

import (
	"bytes"
	"encoding/base64"
	"testing"
)

func TestGenerateSessionToken(t *testing.T) {
	token, err := GenerateSessionToken()
	if err != nil {
		t.Fatal(err)
	}

	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		t.Fatalf("invalid token encoding: %v", err)
	}

	if len(decoded) != SessionTokenBytes {
		t.Fatalf(
			"expected %d bytes, got %d",
			SessionTokenBytes,
			len(decoded),
		)
	}
}

func TestSessionTokensAreUnique(t *testing.T) {
	seen := make(map[string]struct{})

	for i := 0; i < 1000; i++ {
		token, err := GenerateSessionToken()
		if err != nil {
			t.Fatal(err)
		}

		if _, exists := seen[token]; exists {
			t.Fatal("duplicate session token generated")
		}

		seen[token] = struct{}{}
	}
}

func TestSessionTokenHashIsDeterministic(t *testing.T) {
	token := "example-session-token"

	first := HashSessionToken(token)
	second := HashSessionToken(token)

	if !bytes.Equal(first[:], second[:]) {
		t.Fatal("same token must produce same hash")
	}
}

func TestDifferentTokensHaveDifferentHashes(t *testing.T) {
	first := HashSessionToken("token-A")
	second := HashSessionToken("token-B")

	if bytes.Equal(first[:], second[:]) {
		t.Fatal("different tokens produced identical hashes")
	}
}
