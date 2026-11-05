package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/turn"

	"github.com/google/uuid"
)

func TestIceConfigContract(t *testing.T) {
	secret := "test-turn-secret-value"
	svc, err := turn.NewService(turn.Config{
		SharedSecret: secret,
		TURNURLs:     []string{"turn:turn.example.test:3478?transport=udp", "turns:turn.example.test:5349?transport=tcp"},
		STUNURLs:     []string{"stun:turn.example.test:3478"},
		TTL:          5 * time.Minute,
		Realm:        "privacy.test",
	}, 30)
	if err != nil {
		t.Fatal(err)
	}
	user := uuid.New()
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: user, DeviceID: uuid.New(), ExpiresAt: time.Now().Add(time.Hour),
		}},
		TurnHandler: NewTurnHandler(svc),
	})
	req := httptest.NewRequest(http.MethodGet, "/calls/ice-config", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if strings.Contains(body, secret) {
		t.Fatal("secret leaked")
	}
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["ttl_seconds"] == nil || payload["expires_at"] == nil {
		t.Fatalf("missing expiry fields %#v", payload)
	}
	servers, _ := payload["ice_servers"].([]any)
	if len(servers) < 2 {
		t.Fatalf("servers %#v", payload["ice_servers"])
	}
}

func TestIceConfigRejectsInvalidSession(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: revokedAuth{},
		TurnHandler:          NewTurnHandler(nil),
	})
	req := httptest.NewRequest(http.MethodGet, "/calls/ice-config", nil)
	req.Header.Set("Authorization", "Bearer gone")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d", rec.Code)
	}
}

type revokedAuth struct{}

func (revokedAuth) Authenticate(context.Context, string) (auth.AuthenticatedSession, error) {
	return auth.AuthenticatedSession{}, auth.ErrInvalidSession
}

func TestIceConfigUnavailableWithoutIssuer(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: uuid.New(), DeviceID: uuid.New(), ExpiresAt: time.Now().Add(time.Hour),
		}},
		TurnHandler: NewTurnHandler(nil),
	})
	req := httptest.NewRequest(http.MethodGet, "/calls/ice-config", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "secret") {
		t.Fatal("error mentioned secret")
	}
}
