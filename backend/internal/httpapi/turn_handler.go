package httpapi

import (
	"errors"
	"net/http"

	"example.com/private-messenger/backend/internal/turn"

	"github.com/google/uuid"
)

// TurnIssuer issues short-lived ICE credentials for an authenticated user.
type TurnIssuer interface {
	Issue(userID uuid.UUID) (turn.Credentials, error)
}

// TurnHandler serves GET /calls/ice-config.
type TurnHandler struct {
	issuer TurnIssuer
}

func NewTurnHandler(issuer TurnIssuer) *TurnHandler {
	return &TurnHandler{issuer: issuer}
}

func (h *TurnHandler) IceConfig(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	if h.issuer == nil {
		http.Error(w, "TURN unavailable", http.StatusServiceUnavailable)
		return
	}
	cred, err := h.issuer.Issue(session.UserID)
	if err != nil {
		switch {
		case errors.Is(err, turn.ErrRateLimited):
			http.Error(w, "rate limited", http.StatusTooManyRequests)
		case errors.Is(err, turn.ErrInvalidConfig), errors.Is(err, turn.ErrUnavailable):
			http.Error(w, "TURN unavailable", http.StatusServiceUnavailable)
		default:
			http.Error(w, "TURN unavailable", http.StatusServiceUnavailable)
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ice_servers": cred.ICEServers,
		"expires_at":  cred.ExpiresAt,
		"ttl_seconds": cred.TTLSeconds,
	})
}
