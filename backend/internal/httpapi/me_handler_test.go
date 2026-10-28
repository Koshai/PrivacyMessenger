package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
)

func TestMeHandlerReturnsAuthenticatedIdentity(t *testing.T) {
	expected := auth.AuthenticatedSession{
		UserID:    uuid.New(),
		DeviceID:  uuid.New(),
		ExpiresAt: time.Now().Add(24 * time.Hour).UTC(),
	}

	ctx := context.WithValue(
		context.Background(),
		authenticatedSessionKey{},
		expected,
	)

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/me",
		nil,
	).WithContext(ctx)

	rec := httptest.NewRecorder()
	MeHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var response MeResponse
	if err := json.Unmarshal(
		rec.Body.Bytes(),
		&response,
	); err != nil {
		t.Fatal(err)
	}

	if response.UserID != expected.UserID {
		t.Fatal("user ID mismatch")
	}

	if response.DeviceID != expected.DeviceID {
		t.Fatal("device ID mismatch")
	}

	if !response.ExpiresAt.Equal(expected.ExpiresAt) {
		t.Fatal("expiration mismatch")
	}

	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("missing no-store cache header")
	}
}

func TestMeHandlerRejectsMissingIdentity(t *testing.T) {
	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/me",
		nil,
	)

	rec := httptest.NewRecorder()
	MeHandler(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestMeRouteRequiresAuthentication(t *testing.T) {
	router := NewRouterWithSessions(
		nil,
		nil,
		fakeSessionAuthenticator{
			err: auth.ErrInvalidSession,
		},
	)

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/me",
		nil,
	)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestMeRouteAcceptsValidSession(t *testing.T) {
	expected := auth.AuthenticatedSession{
		UserID:    uuid.New(),
		DeviceID:  uuid.New(),
		ExpiresAt: time.Now().Add(time.Hour).UTC(),
	}

	router := NewRouterWithSessions(
		nil,
		nil,
		fakeSessionAuthenticator{
			session: expected,
		},
	)

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/me",
		nil,
	)
	req.Header.Set("Authorization", "Bearer test-token")

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf(
			"expected 200, got %d: %s",
			rec.Code,
			rec.Body.String(),
		)
	}
}
