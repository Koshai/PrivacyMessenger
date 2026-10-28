package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type MeResponse struct {
	UserID    uuid.UUID `json:"user_id"`
	DeviceID  uuid.UUID `json:"device_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

func MeHandler(
	w http.ResponseWriter,
	r *http.Request,
) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(
			w,
			"authentication required",
			http.StatusUnauthorized,
		)
		return
	}

	response := MeResponse{
		UserID:    session.UserID,
		DeviceID:  session.DeviceID,
		ExpiresAt: session.ExpiresAt,
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")

	_ = json.NewEncoder(w).Encode(response)
}
