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

type SessionDisconnecter interface {
	DisconnectToken(token string, reason string)
}

type LogoutHandler struct {
	revoker      SessionRevoker
	disconnecter SessionDisconnecter
	callEnder    CallTerminator
}

func NewLogoutHandler(
	revoker SessionRevoker,
) *LogoutHandler {
	return &LogoutHandler{revoker: revoker}
}

func (h *LogoutHandler) WithDisconnecter(d SessionDisconnecter) *LogoutHandler {
	h.disconnecter = d
	return h
}

func (h *LogoutHandler) WithCallEnder(c CallTerminator) *LogoutHandler {
	h.callEnder = c
	return h
}

func (h *LogoutHandler) Logout(
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

	if h.callEnder != nil {
		_ = h.callEnder.EndCallsForUser(r.Context(), session.UserID)
	}

	if h.disconnecter != nil {
		h.disconnecter.DisconnectToken(token, "logout")
	}

	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
