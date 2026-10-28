package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"example.com/private-messenger/backend/internal/auth"
)

func TestConfiguredRouterHealth(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{})

	req := httptest.NewRequest(
		http.MethodGet,
		"/health",
		nil,
	)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf(
			"expected 200, got %d",
			rec.Code,
		)
	}
}

func TestConfiguredRouterProtectedRoute(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{
			err: auth.ErrInvalidSession,
		},
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/me",
		nil,
	)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf(
			"expected 401, got %d",
			rec.Code,
		)
	}
}

func TestConfiguredRouterRejectsWrongMethod(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{},
	})

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/me",
		nil,
	)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf(
			"expected 405, got %d",
			rec.Code,
		)
	}
}

func TestConfiguredRouterLogoutRegistration(t *testing.T) {
	revoker := &fakeSessionRevoker{}

	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{},
		LogoutHandler:        NewLogoutHandler(revoker),
	})

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/logout",
		nil,
	)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf(
			"expected 401, got %d",
			rec.Code,
		)
	}

	if revoker.called {
		t.Fatal("revoker must not run without authentication")
	}
}
