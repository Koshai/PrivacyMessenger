package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAuthRouteRegistration(t *testing.T) {
	mux := http.NewServeMux()

	RegisterAuthRoutes(
		mux,
		NewAuthHandler(nil),
	)

	request := httptest.NewRequest(
		http.MethodGet,
		"/auth/request-otp",
		nil,
	)

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf(
			"expected 405, got %d",
			recorder.Code,
		)
	}
}

func TestRouterRegistersVerifyOTP(t *testing.T) {
	router := NewRouterWithAuthentication(
		nil,
		NewVerifyOTPHandler(nil),
	)

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/verify-otp",
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
