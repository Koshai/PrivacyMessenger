package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
)

type fakeSessionRevoker struct {
	called bool
	token  string
	err    error
}

func (f *fakeSessionRevoker) Revoke(
	ctx context.Context,
	token string,
) error {
	f.called = true
	f.token = token
	return f.err
}

func TestLogoutRejectsMissingAuthentication(t *testing.T) {
	revoker := &fakeSessionRevoker{}
	handler := NewLogoutHandler(revoker)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/logout",
		nil,
	)

	rec := httptest.NewRecorder()
	handler.Logout(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}

	if revoker.called {
		t.Fatal("revoker should not be called")
	}
}

func TestLogoutRevokesCurrentSession(t *testing.T) {
	revoker := &fakeSessionRevoker{}
	handler := NewLogoutHandler(revoker)

	session := auth.AuthenticatedSession{
		UserID:   uuid.New(),
		DeviceID: uuid.New(),
	}

	ctx := context.WithValue(
		context.Background(),
		authenticatedSessionKey{},
		session,
	)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/logout",
		nil,
	).WithContext(ctx)

	req.Header.Set(
		"Authorization",
		"Bearer test-session-token",
	)

	rec := httptest.NewRecorder()
	handler.Logout(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}

	if !revoker.called {
		t.Fatal("revoker was not called")
	}

	if revoker.token != "test-session-token" {
		t.Fatal("wrong session token revoked")
	}
}

func TestLogoutHandlesRepositoryFailure(t *testing.T) {
	revoker := &fakeSessionRevoker{
		err: errors.New("database unavailable"),
	}

	handler := NewLogoutHandler(revoker)

	ctx := context.WithValue(
		context.Background(),
		authenticatedSessionKey{},
		auth.AuthenticatedSession{
			UserID: uuid.New(),
		},
	)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/logout",
		nil,
	).WithContext(ctx)

	req.Header.Set("Authorization", "Bearer test-token")

	rec := httptest.NewRecorder()
	handler.Logout(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
}
