package httpapi

import "net/http"

func RegisterMessagingRoutes(
	mux *http.ServeMux,
	authenticator SessionAuthenticator,
	handler *MessagingHandler,
) {
	protect := func(next http.HandlerFunc) http.Handler {
		return RequireAuthentication(authenticator, next)
	}

	mux.Handle("POST /conversations", protect(handler.OpenConversation))
	mux.Handle("POST /conversations/{conversationID}/envelopes", protect(handler.SendEnvelope))
	mux.Handle("GET /conversations/{conversationID}/envelopes", protect(handler.ListHistory))
	mux.Handle("POST /envelopes/{envelopeID}/ack", protect(handler.Acknowledge))
	mux.Handle("GET /envelopes/pending", protect(handler.SyncPending))
}
