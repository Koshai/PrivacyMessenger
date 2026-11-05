// Package turn issues short-lived coturn REST credentials.
// The shared secret never leaves the server.
package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	MinTTL = 60 * time.Second
	MaxTTL = time.Hour
)

var (
	ErrInvalidConfig = errors.New("invalid turn configuration")
	ErrRateLimited   = errors.New("turn credential rate limited")
	ErrUnavailable   = errors.New("turn unavailable")
)

// ICEServer is a client-safe ICE server entry (no shared secret).
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// Credentials are temporary TURN REST credentials plus public STUN/TURN URLs.
type Credentials struct {
	Username   string      `json:"username"`
	Credential string      `json:"credential"`
	ExpiresAt  time.Time   `json:"expires_at"`
	TTLSeconds int         `json:"ttl_seconds"`
	ICEServers []ICEServer `json:"ice_servers"`
}

// Config is server-side TURN configuration.
type Config struct {
	SharedSecret string
	TURNURLs     []string
	STUNURLs     []string
	TTL          time.Duration
	Realm        string
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.SharedSecret) == "" {
		return fmt.Errorf("%w: shared secret required", ErrInvalidConfig)
	}
	if len(c.SharedSecret) < 16 {
		return fmt.Errorf("%w: shared secret too short", ErrInvalidConfig)
	}
	if c.TTL < MinTTL || c.TTL > MaxTTL {
		return fmt.Errorf("%w: ttl out of range", ErrInvalidConfig)
	}
	if len(c.TURNURLs) == 0 {
		return fmt.Errorf("%w: at least one TURN url required", ErrInvalidConfig)
	}
	for _, raw := range append(append([]string{}, c.TURNURLs...), c.STUNURLs...) {
		u := strings.TrimSpace(raw)
		if u == "" {
			return fmt.Errorf("%w: empty url", ErrInvalidConfig)
		}
		if strings.Contains(u, c.SharedSecret) {
			return fmt.Errorf("%w: secret must not appear in urls", ErrInvalidConfig)
		}
		lower := strings.ToLower(u)
		if strings.HasPrefix(lower, "turn:") || strings.HasPrefix(lower, "turns:") || strings.HasPrefix(lower, "stun:") || strings.HasPrefix(lower, "stuns:") {
			continue
		}
		return fmt.Errorf("%w: unsupported ice url %q", ErrInvalidConfig, u)
	}
	for _, u := range c.TURNURLs {
		lower := strings.ToLower(u)
		if !strings.HasPrefix(lower, "turn:") && !strings.HasPrefix(lower, "turns:") {
			return fmt.Errorf("%w: TURN url required, got %q", ErrInvalidConfig, u)
		}
	}
	return nil
}

// Issue builds coturn use-auth-secret credentials.
// username = "<expiry-unix>:<user-id>"
// credential = base64(HMAC-SHA1(sharedSecret, username))
func Issue(cfg Config, userID uuid.UUID, now time.Time) (Credentials, error) {
	if err := cfg.Validate(); err != nil {
		return Credentials{}, err
	}
	if userID == uuid.Nil {
		return Credentials{}, fmt.Errorf("%w: user required", ErrInvalidConfig)
	}
	expires := now.UTC().Add(cfg.TTL).Truncate(time.Second)
	username := fmt.Sprintf("%d:%s", expires.Unix(), userID.String())
	mac := hmac.New(sha1.New, []byte(cfg.SharedSecret))
	_, _ = mac.Write([]byte(username))
	password := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	servers := make([]ICEServer, 0, 1+len(cNonEmpty(cfg.STUNURLs)))
	if len(cfg.STUNURLs) > 0 {
		servers = append(servers, ICEServer{URLs: append([]string{}, cfg.STUNURLs...)})
	}
	servers = append(servers, ICEServer{
		URLs:       append([]string{}, cfg.TURNURLs...),
		Username:   username,
		Credential: password,
	})
	return Credentials{
		Username:   username,
		Credential: password,
		ExpiresAt:  expires,
		TTLSeconds: int(cfg.TTL.Seconds()),
		ICEServers: servers,
	}, nil
}

func cNonEmpty(v []string) []string { return v }

// ContainsSecret reports whether payload accidentally includes the shared secret.
func ContainsSecret(cfg Config, payload string) bool {
	secret := strings.TrimSpace(cfg.SharedSecret)
	return secret != "" && strings.Contains(payload, secret)
}
