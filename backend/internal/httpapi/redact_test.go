package httpapi

import "testing"

func TestRedactSecretsScrubsBearerTokens(t *testing.T) {
	in := `unauthorized Authorization: Bearer super-secret-token-value path=/x`
	out := RedactSecrets(in)
	if out == in {
		t.Fatal("expected redaction")
	}
	if !AuthorizationHeaderIsRedacted(out) {
		t.Fatalf("expected [REDACTED], got %q", out)
	}
	if contains(out, "super-secret-token-value") {
		t.Fatalf("token leaked: %q", out)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 ||
		(len(s) > 0 && (indexOf(s, sub) >= 0)))
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
