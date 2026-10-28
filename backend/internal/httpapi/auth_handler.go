package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"example.com/private-messenger/backend/internal/auth"
)

type AuthHandler struct {
	requests *auth.OTPRequestService
}

func NewAuthHandler(
	requests *auth.OTPRequestService,
) *AuthHandler {
	return &AuthHandler{requests: requests}
}

type requestOTPBody struct {
	Email string `json:"email"`
}

type requestOTPResponse struct {
	Message string `json:"message"`
}

func (h *AuthHandler) RequestOTP(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4096)

	var body requestOTPBody
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&body); err != nil {
		http.Error(w, "invalid JSON request", http.StatusBadRequest)
		return
	}

	// A request must contain exactly one JSON object.
	// Reject trailing JSON values or other non-whitespace data.
	var extra any

	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(
			w,
			"request must contain exactly one JSON object",
			http.StatusBadRequest,
		)
		return
	}

	// Do not reveal whether an account exists.
	_, err := h.requests.Request(r.Context(), body.Email)

	switch {
	case errors.Is(err, auth.ErrInvalidEmail):
		http.Error(w, "invalid email", http.StatusBadRequest)
		return

	case errors.Is(err, auth.ErrOTPRateLimited):
		w.Header().Set("Retry-After", "900")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return

	case err != nil:
		http.Error(w, "request failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)

	_ = json.NewEncoder(w).Encode(requestOTPResponse{
		Message: "If delivery is available, a verification code has been sent.",
	})
}
