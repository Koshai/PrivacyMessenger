package auth

import (
	"crypto/rand"
	"regexp"
	"testing"
)

func testSecret(t *testing.T) []byte {
	t.Helper()

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	return secret
}

func TestGenerateOTP(t *testing.T) {
	pattern := regexp.MustCompile(`^[0-9]{6}$`)

	for i := 0; i < 1000; i++ {
		code, err := GenerateOTP()
		if err != nil {
			t.Fatal(err)
		}

		if !pattern.MatchString(code) {
			t.Fatalf("invalid OTP format: %q", code)
		}
	}
}

func TestHashAndVerifyOTP(t *testing.T) {
	secret := testSecret(t)
	challengeID := "challenge-123"
	code := "012345"

	hash, err := HashOTP(secret, challengeID, code)
	if err != nil {
		t.Fatal(err)
	}

	if !VerifyOTPHash(secret, challengeID, code, hash) {
		t.Fatal("correct OTP should verify")
	}

	if VerifyOTPHash(secret, challengeID, "999999", hash) {
		t.Fatal("incorrect OTP should fail")
	}
}

func TestOTPHashBoundToChallenge(t *testing.T) {
	secret := testSecret(t)

	hash, err := HashOTP(secret, "challenge-A", "123456")
	if err != nil {
		t.Fatal(err)
	}

	if VerifyOTPHash(secret, "challenge-B", "123456", hash) {
		t.Fatal("OTP must not verify for another challenge")
	}
}

func TestOTPRejectsWeakSecret(t *testing.T) {
	_, err := HashOTP(
		[]byte("short"),
		"challenge-123",
		"123456",
	)

	if err == nil {
		t.Fatal("expected weak secret rejection")
	}
}

func TestOTPRejectsNonNumericCode(t *testing.T) {
	secret := testSecret(t)

	_, err := HashOTP(
		secret,
		"challenge-123",
		"12AB56",
	)

	if err == nil {
		t.Fatal("expected nonnumeric OTP rejection")
	}
}
