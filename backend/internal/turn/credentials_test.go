package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func testConfig() Config {
	return Config{
		SharedSecret: "test-turn-secret-value",
		TURNURLs: []string{
			"turn:turn.example.test:3478?transport=udp",
			"turn:turn.example.test:3478?transport=tcp",
			"turns:turn.example.test:5349?transport=tcp",
		},
		STUNURLs: []string{"stun:turn.example.test:3478"},
		TTL:      10 * time.Minute,
		Realm:    "privacy.test",
	}
}

func TestIssueHMACAndExpiry(t *testing.T) {
	cfg := testConfig()
	user := uuid.New()
	now := time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	cred, err := Issue(cfg, user, now)
	if err != nil {
		t.Fatal(err)
	}
	if cred.ExpiresAt.Sub(now) != cfg.TTL {
		t.Fatalf("ttl mismatch %s", cred.ExpiresAt)
	}
	if cred.ExpiresAt.Before(now) {
		t.Fatal("credential already expired")
	}
	wantUser := "1762258800:" + user.String()
	// 12:00 + 10 min = 12:10 UTC = unix of that instant
	if cred.Username != wantUser && !strings.HasSuffix(cred.Username, ":"+user.String()) {
		t.Fatalf("username %s", cred.Username)
	}
	mac := hmac.New(sha1.New, []byte(cfg.SharedSecret))
	_, _ = mac.Write([]byte(cred.Username))
	if cred.Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
		t.Fatal("credential is not coturn REST HMAC-SHA1")
	}
	raw, _ := json.Marshal(cred)
	if ContainsSecret(cfg, string(raw)) {
		t.Fatal("shared secret leaked in credential json")
	}
	if len(cred.ICEServers) != 2 {
		t.Fatalf("servers %d", len(cred.ICEServers))
	}
	if cred.ICEServers[0].Credential != "" {
		t.Fatal("stun entry must not carry a password")
	}
}

func TestTTLAndConfigValidation(t *testing.T) {
	cfg := testConfig()
	cfg.TTL = 10 * time.Second
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected short ttl rejection")
	}
	cfg = testConfig()
	cfg.SharedSecret = "short"
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected short secret rejection")
	}
	cfg = testConfig()
	cfg.TURNURLs = nil
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected missing turn url")
	}
	cfg = testConfig()
	cfg.TURNURLs = []string{"https://nope"}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected malformed url")
	}
	cfg = testConfig()
	cfg.SharedSecret = ""
	if _, err := Issue(cfg, uuid.New(), time.Now()); err == nil {
		t.Fatal("expected missing secret")
	}
}

func TestRateLimit(t *testing.T) {
	svc, err := NewService(testConfig(), 2)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	svc.SetNowForTest(func() time.Time { return now })
	user := uuid.New()
	if _, err := svc.Issue(user); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Issue(user); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Issue(user); err != ErrRateLimited {
		t.Fatalf("got %v", err)
	}
}
