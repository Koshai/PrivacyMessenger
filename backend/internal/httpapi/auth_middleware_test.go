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

type fakeSessionAuthenticator struct {
	session auth.AuthenticatedSession
	err     error
}

func (f fakeSessionAuthenticator) Authenticate(
	ctx context.Context,
	token string,
) (auth.AuthenticatedSession, error) {
	return f.session, f.err
}

func TestAuthMiddlewareRejectsMissingToken(t *testing.T) {
	next := http.HandlerFunc(func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		t.Fatal("protected handler should not execute")
	})

	middleware := RequireAuthentication(
		fakeSessionAuthenticator{},
		next,
	)

	req := httptest.NewRequest(http.MethodGet, "/auth/me", nil)
	rec := httptest.NewRecorder()

	middleware.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestAuthMiddlewareRejectsInvalidToken(t *testing.T) {
	next := http.HandlerFunc(func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		t.Fatal("protected handler should not execute")
	})

	middleware := RequireAuthentication(
		fakeSessionAuthenticator{
			err: auth.ErrInvalidSession,
		},
		next,
	)

	req := httptest.NewRequest(http.MethodGet, "/auth/me", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")

	rec := httptest.NewRecorder()
	middleware.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestAuthMiddlewareAddsSessionToContext(t *testing.T) {
	expected := auth.AuthenticatedSession{
		UserID:   uuid.New(),
		DeviceID: uuid.New(),
	}

	next := http.HandlerFunc(func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		session, ok := SessionFromContext(r.Context())
		if !ok {
			t.Fatal("authenticated session missing")
		}

		if session.UserID != expected.UserID {
			t.Fatal("user ID mismatch")
		}

		if session.DeviceID != expected.DeviceID {
			t.Fatal("device ID mismatch")
		}

		w.WriteHeader(http.StatusOK)
	})

	middleware := RequireAuthentication(
		fakeSessionAuthenticator{
			session: expected,
		},
		next,
	)

	req := httptest.NewRequest(http.MethodGet, "/auth/me", nil)
	req.Header.Set("Authorization", "Bearer test-token")

	rec := httptest.NewRecorder()
	middleware.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestAuthMiddlewareHandlesRepositoryFailure(t *testing.T) {
	next := http.HandlerFunc(func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		t.Fatal("protected handler should not execute")
	})

	middleware := RequireAuthentication(
		fakeSessionAuthenticator{
			err: errors.New("database unavailable"),
		},
		next,
	)

	req := httptest.NewRequest(http.MethodGet, "/auth/me", nil)
	req.Header.Set("Authorization", "Bearer test-token")

	rec := httptest.NewRecorder()
	middleware.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
}
