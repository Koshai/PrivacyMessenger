package httpapi

import (
	"encoding/json"
	"net/http"
)

// RouterDependencies contains the services needed
// to register HTTP endpoints.
type RouterDependencies struct {
	AuthHandler          *AuthHandler
	VerifyHandler        *VerifyOTPHandler
	SessionAuthenticator SessionAuthenticator
	LogoutHandler        *LogoutHandler
}

// NewConfiguredRouter is the central router factory.
// All route registration happens here.
func NewConfiguredRouter(
	deps RouterDependencies,
) http.Handler {
	mux := http.NewServeMux()

	// Public health endpoint.
	mux.HandleFunc("GET /health", func(
		w http.ResponseWriter,
		r *http.Request,
	) {
		w.Header().Set("Content-Type", "application/json")

		_ = json.NewEncoder(w).Encode(
			HealthResponse{Status: "ok"},
		)
	})

	// Public authentication endpoints.
	if deps.AuthHandler != nil {
		RegisterAuthRoutes(mux, deps.AuthHandler)
	}

	if deps.VerifyHandler != nil {
		mux.HandleFunc(
			"POST /auth/verify-otp",
			deps.VerifyHandler.VerifyOTP,
		)
	}

	// Protected endpoints.
	if deps.SessionAuthenticator != nil {
		mux.Handle(
			"GET /auth/me",
			RequireAuthentication(
				deps.SessionAuthenticator,
				http.HandlerFunc(MeHandler),
			),
		)

		if deps.LogoutHandler != nil {
			mux.Handle(
				"POST /auth/logout",
				RequireAuthentication(
					deps.SessionAuthenticator,
					http.HandlerFunc(
						deps.LogoutHandler.Logout,
					),
				),
			)
		}
	}

	return mux
}

// HealthResponse is retained for existing tests.
type HealthResponse struct {
	Status string `json:"status"`
}

// Compatibility constructors.
// These now delegate to the central router.

func NewRouter() http.Handler {
	return NewConfiguredRouter(RouterDependencies{})
}

func NewRouterWithAuth(
	authHandler *AuthHandler,
) http.Handler {
	return NewConfiguredRouter(RouterDependencies{
		AuthHandler: authHandler,
	})
}

func NewRouterWithAuthentication(
	authHandler *AuthHandler,
	verifyHandler *VerifyOTPHandler,
) http.Handler {
	return NewConfiguredRouter(RouterDependencies{
		AuthHandler:   authHandler,
		VerifyHandler: verifyHandler,
	})
}

func NewRouterWithSessions(
	authHandler *AuthHandler,
	verifyHandler *VerifyOTPHandler,
	sessionAuthenticator SessionAuthenticator,
) http.Handler {
	return NewConfiguredRouter(RouterDependencies{
		AuthHandler:          authHandler,
		VerifyHandler:        verifyHandler,
		SessionAuthenticator: sessionAuthenticator,
	})
}

func NewRouterWithLogout(
	authHandler *AuthHandler,
	verifyHandler *VerifyOTPHandler,
	sessionAuthenticator SessionAuthenticator,
	logoutHandler *LogoutHandler,
) http.Handler {
	return NewConfiguredRouter(RouterDependencies{
		AuthHandler:          authHandler,
		VerifyHandler:        verifyHandler,
		SessionAuthenticator: sessionAuthenticator,
		LogoutHandler:        logoutHandler,
	})
}
