package httpapi

import "net/http"

// RegisterAuthRoutes attaches authentication endpoints
// to an existing ServeMux.
func RegisterAuthRoutes(
	mux *http.ServeMux,
	handler *AuthHandler,
) {
	mux.HandleFunc(
		"/auth/request-otp",
		handler.RequestOTP,
	)
}
