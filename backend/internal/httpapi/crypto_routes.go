package httpapi

import "net/http"

func RegisterCryptoRoutes(
	mux *http.ServeMux,
	auth SessionAuthenticator,
	handler *CryptoHandler,
) {
	protect := func(h http.HandlerFunc) http.Handler {
		return RequireAuthentication(auth, h)
	}
	mux.Handle("POST /crypto/identity", protect(handler.RegisterIdentity))
	mux.Handle("POST /crypto/key-packages", protect(handler.UploadKeyPackages))
	mux.Handle("GET /crypto/key-packages/status", protect(handler.PoolStatus))
	mux.Handle("POST /crypto/users/{userID}/key-packages/claim", protect(handler.ClaimKeyPackage))
	mux.Handle("GET /crypto/users/{userID}/identities", protect(handler.PeerIdentities))
	mux.Handle("POST /crypto/device/revoke", protect(handler.RevokeCurrentDevice))
}
