package httpapi

import (
	"context"
	"errors"
	"net/http"

	"example.com/private-messenger/backend/internal/auth"
)

type SessionRevoker interface {
	Revoke(ctx context.Context, token string) error
}

type LogoutHandler struct {
	revoker SessionRevoker
}

func NewLogoutHandler(
	revoker SessionRevoker,
) *LogoutHandler {
	return &LogoutHandler{revoker: revoker}
}

func (h *LogoutHandler) Logout(
	w http.ResponseWriter,
	r *http.Request,
) {
	if _, ok := SessionFromContext(r.Context()); !ok {
		http.Error(
			w,
			"authentication required",
			http.StatusUnauthorized,
		)
		return
	}

	token, err := ParseBearerToken(r.Header)
	if err != nil {
		http.Error(
			w,
			"authentication required",
			http.StatusUnauthorized,
		)
		return
	}

	if h.revoker == nil {
		http.Error(
			w,
			"logout unavailable",
			http.StatusServiceUnavailable,
		)
		return
	}

	err = h.revoker.Revoke(r.Context(), token)

	if errors.Is(err, auth.ErrInvalidSession) {
		http.Error(
			w,
			"invalid or expired session",
			http.StatusUnauthorized,
		)
		return
	}

	if err != nil {
		http.Error(
			w,
			"logout failed",
			http.StatusInternalServerError,
		)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
