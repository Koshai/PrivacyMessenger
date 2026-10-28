package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequestOTPRejectsWrongMethod(t *testing.T) {
	handler := NewAuthHandler(nil)

	request := httptest.NewRequest(
		http.MethodGet,
		"/auth/request-otp",
		nil,
	)
	recorder := httptest.NewRecorder()

	handler.RequestOTP(recorder, request)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", recorder.Code)
	}
}

func TestRequestOTPRejectsInvalidJSON(t *testing.T) {
	handler := NewAuthHandler(nil)

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		strings.NewReader(`{"email":`),
	)
	recorder := httptest.NewRecorder()

	handler.RequestOTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", recorder.Code)
	}
}

func TestRequestOTPRejectsUnknownFields(t *testing.T) {
	handler := NewAuthHandler(nil)

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		strings.NewReader(
			`{"email":"user@example.com","admin":true}`,
		),
	)
	recorder := httptest.NewRecorder()

	handler.RequestOTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", recorder.Code)
	}
}

func TestRequestOTPRejectsMultipleJSONObjects(t *testing.T) {
	handler := NewAuthHandler(nil)

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		strings.NewReader(
			`{"email":"user@example.com"}{"email":"other@example.com"}`,
		),
	)
	recorder := httptest.NewRecorder()

	handler.RequestOTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf(
			"expected 400, got %d",
			recorder.Code,
		)
	}
}

func TestRequestOTPRejectsEmptyBody(t *testing.T) {
	handler := NewAuthHandler(nil)

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		strings.NewReader(""),
	)
	recorder := httptest.NewRecorder()

	handler.RequestOTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf(
			"expected 400, got %d",
			recorder.Code,
		)
	}
}

func TestRouterWithAuthRegistersRequestOTP(t *testing.T) {
	router := NewRouterWithAuth(NewAuthHandler(nil))

	request := httptest.NewRequest(
		http.MethodGet,
		"/auth/request-otp",
		nil,
	)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf(
			"expected 405, got %d",
			recorder.Code,
		)
	}
}
