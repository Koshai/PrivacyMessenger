package httpapi

import "net/http"

func RegisterCallingRoutes(
	mux *http.ServeMux,
	auth SessionAuthenticator,
	handler *CallingHandler,
) {
	protect := func(h http.HandlerFunc) http.Handler {
		return RequireAuthentication(auth, h)
	}
	mux.Handle("POST /calls", protect(handler.Initiate))
	mux.Handle("GET /calls/active", protect(handler.Active))
	mux.Handle("GET /calls/{callID}", protect(handler.Get))
	mux.Handle("POST /calls/{callID}/accept", protect(handler.Accept))
	mux.Handle("POST /calls/{callID}/decline", protect(handler.Decline))
	mux.Handle("POST /calls/{callID}/cancel", protect(handler.Cancel))
	mux.Handle("POST /calls/{callID}/hangup", protect(handler.HangUp))
	mux.Handle("PUT /calls/{callID}/offer", protect(handler.SetOffer))
	mux.Handle("PUT /calls/{callID}/answer", protect(handler.SetAnswer))
	mux.Handle("POST /calls/{callID}/connected", protect(handler.MarkConnected))
	mux.Handle("POST /calls/{callID}/ice", protect(handler.AddICE))
	mux.Handle("GET /calls/{callID}/ice", protect(handler.ListICE))
}

func RegisterCallAuthRoutes(mux *http.ServeMux, auth SessionAuthenticator, handler *CallAuthHandler) {
	protect := func(h http.HandlerFunc) http.Handler {
		return RequireAuthentication(auth, h)
	}
	mux.Handle("POST /calls/auth-key", protect(handler.RegisterKey))
	mux.Handle("POST /calls/{callID}/auth", protect(handler.Submit))
	mux.Handle("GET /calls/{callID}/auth", protect(handler.List))
}
