package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
)

type OTPVerifier interface {
	VerifyAndLogin(
		ctx context.Context,
		challengeID uuid.UUID,
		code string,
		deviceName string,
	) (auth.LoginResult, error)
}

type VerifyOTPHandler struct {
	verifier OTPVerifier
}

func NewVerifyOTPHandler(
	verifier OTPVerifier,
) *VerifyOTPHandler {
	return &VerifyOTPHandler{verifier: verifier}
}

type verifyOTPBody struct {
	ChallengeID string `json:"challenge_id"`
	Code        string `json:"code"`
	DeviceName  string `json:"device_name"`
}

type verifyOTPResponse struct {
	UserID    uuid.UUID `json:"user_id"`
	DeviceID  uuid.UUID `json:"device_id"`
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

func (h *VerifyOTPHandler) VerifyOTP(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4096)

	var body verifyOTPBody
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&body); err != nil {
		http.Error(w, "invalid JSON request", http.StatusBadRequest)
		return
	}

	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(w, "invalid JSON request", http.StatusBadRequest)
		return
	}

	challengeID, err := uuid.Parse(body.ChallengeID)
	if err != nil {
		http.Error(w, "invalid challenge ID", http.StatusBadRequest)
		return
	}

	if len(body.Code) != 6 {
		http.Error(w, "invalid verification code", http.StatusBadRequest)
		return
	}

	for _, char := range body.Code {
		if char < '0' || char > '9' {
			http.Error(w, "invalid verification code", http.StatusBadRequest)
			return
		}
	}

	deviceName := strings.TrimSpace(body.DeviceName)
	if deviceName == "" || len(deviceName) > 100 {
		http.Error(w, "invalid device name", http.StatusBadRequest)
		return
	}

	if h.verifier == nil {
		http.Error(w, "service unavailable", http.StatusServiceUnavailable)
		return
	}

	result, err := h.verifier.VerifyAndLogin(
		r.Context(),
		challengeID,
		body.Code,
		deviceName,
	)

	switch {
	case errors.Is(err, auth.ErrInvalidOTP),
		errors.Is(err, auth.ErrChallengeNotFound),
		errors.Is(err, auth.ErrChallengeExpired),
		errors.Is(err, auth.ErrChallengeUsed),
		errors.Is(err, auth.ErrChallengeLocked):
		http.Error(w, "invalid or expired verification code", http.StatusUnauthorized)
		return

	case err != nil:
		http.Error(w, "verification failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")

	_ = json.NewEncoder(w).Encode(verifyOTPResponse{
		UserID:    result.UserID,
		DeviceID:  result.DeviceID,
		Token:     result.Token,
		ExpiresAt: result.ExpiresAt,
	})
}
