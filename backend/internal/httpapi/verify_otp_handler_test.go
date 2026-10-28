package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestVerifyOTPRejectsWrongMethod(t *testing.T) {
	handler := NewVerifyOTPHandler(nil)

	req := httptest.NewRequest(
		http.MethodGet,
		"/auth/verify-otp",
		nil,
	)
	rec := httptest.NewRecorder()

	handler.VerifyOTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", rec.Code)
	}
}

func TestVerifyOTPRejectsMalformedJSON(t *testing.T) {
	handler := NewVerifyOTPHandler(nil)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		strings.NewReader(`{"challenge_id":`),
	)
	rec := httptest.NewRecorder()

	handler.VerifyOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestVerifyOTPRejectsInvalidChallengeID(t *testing.T) {
	handler := NewVerifyOTPHandler(nil)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		strings.NewReader(`{
			"challenge_id":"invalid",
			"code":"123456",
			"device_name":"Android"
		}`),
	)
	rec := httptest.NewRecorder()

	handler.VerifyOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestVerifyOTPRejectsInvalidCode(t *testing.T) {
	handler := NewVerifyOTPHandler(nil)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		strings.NewReader(`{
			"challenge_id":"550e8400-e29b-41d4-a716-446655440000",
			"code":"12AB56",
			"device_name":"Android"
		}`),
	)
	rec := httptest.NewRecorder()

	handler.VerifyOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestVerifyOTPRejectsMissingDeviceName(t *testing.T) {
	handler := NewVerifyOTPHandler(nil)

	req := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		strings.NewReader(`{
			"challenge_id":"550e8400-e29b-41d4-a716-446655440000",
			"code":"123456",
			"device_name":""
		}`),
	)
	rec := httptest.NewRecorder()

	handler.VerifyOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
