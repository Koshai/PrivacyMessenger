package httpapi

import (
	"context"
	"errors"
	"net/http"

	"example.com/private-messenger/backend/internal/auth"
)

type SessionAuthenticator interface {
	Authenticate(
		ctx context.Context,
		token string,
	) (auth.AuthenticatedSession, error)
}

type authenticatedSessionKey struct{}

func SessionFromContext(
	ctx context.Context,
) (auth.AuthenticatedSession, bool) {
	session, ok := ctx.Value(
		authenticatedSessionKey{},
	).(auth.AuthenticatedSession)

	return session, ok
}

func RequireAuthentication(
	authenticator SessionAuthenticator,
	next http.Handler,
) http.Handler {
	return http.HandlerFunc(func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		token, err := ParseBearerToken(r.Header)
		if err != nil {
			http.Error(
				w,
				"authentication required",
				http.StatusUnauthorized,
			)
			return
		}

		if authenticator == nil {
			http.Error(
				w,
				"authentication unavailable",
				http.StatusServiceUnavailable,
			)
			return
		}

		session, err := authenticator.Authenticate(
			r.Context(),
			token,
		)

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
				"authentication failed",
				http.StatusInternalServerError,
			)
			return
		}

		ctx := context.WithValue(
			r.Context(),
			authenticatedSessionKey{},
			session,
		)

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
