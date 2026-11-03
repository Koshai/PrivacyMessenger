package httpapi

import "net/http"

func RegisterFriendsRoutes(
	mux *http.ServeMux,
	authenticator SessionAuthenticator,
	handler *FriendsHandler,
) {
	protect := func(next http.HandlerFunc) http.Handler {
		return RequireAuthentication(authenticator, next)
	}

	mux.Handle("POST /friends/requests", protect(handler.CreateRequest))
	mux.Handle("GET /friends/requests/incoming", protect(handler.ListIncoming))
	mux.Handle("GET /friends/requests/outgoing", protect(handler.ListOutgoing))
	mux.Handle("POST /friends/requests/{id}/accept", protect(handler.Accept))
	mux.Handle("POST /friends/requests/{id}/reject", protect(handler.Reject))
	mux.Handle("GET /friends", protect(handler.ListFriends))
	mux.Handle("GET /friends/count", protect(handler.FriendCount))
	mux.Handle("DELETE /friends/{userID}", protect(handler.RemoveFriend))
	mux.Handle("POST /friends/blocks", protect(handler.Block))
	mux.Handle("DELETE /friends/blocks/{userID}", protect(handler.Unblock))
	mux.Handle("GET /friends/blocks", protect(handler.ListBlocked))
}
