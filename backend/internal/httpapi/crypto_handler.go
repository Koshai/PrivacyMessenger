package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"example.com/private-messenger/backend/internal/crypto"

	"github.com/google/uuid"
)

type CryptoService interface {
	RegisterIdentity(ctx context.Context, actorUserID, actorDeviceID uuid.UUID, publicKey []byte) (crypto.DeviceIdentity, bool, error)
	GetPeerIdentities(ctx context.Context, actorUserID, peerUserID uuid.UUID) ([]crypto.DeviceIdentity, error)
	UploadKeyPackages(ctx context.Context, actorUserID, actorDeviceID uuid.UUID, packages [][]byte, ttl time.Duration) error
	ClaimKeyPackage(ctx context.Context, actorUserID, peerUserID uuid.UUID) (crypto.KeyPackage, crypto.DeviceIdentity, error)
	PackagePoolStatus(ctx context.Context, actorUserID, actorDeviceID uuid.UUID) (int, bool, error)
	RevokeDevice(ctx context.Context, actorUserID, deviceID uuid.UUID) error
}

type CryptoHandler struct {
	service CryptoService
}

func NewCryptoHandler(service CryptoService) *CryptoHandler {
	return &CryptoHandler{service: service}
}

func (h *CryptoHandler) RegisterIdentity(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	var body struct {
		PublicKeyB64 string `json:"public_key_b64"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	pub, err := base64.StdEncoding.DecodeString(body.PublicKeyB64)
	if err != nil {
		http.Error(w, "invalid public_key_b64", http.StatusBadRequest)
		return
	}
	id, created, err := h.service.RegisterIdentity(r.Context(), session.UserID, session.DeviceID, pub)
	if err != nil {
		writeCryptoError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]any{
		"device_id":        id.DeviceID.String(),
		"fingerprint_hex": id.FingerprintHex,
		"created":         created,
	})
}

func (h *CryptoHandler) UploadKeyPackages(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	var body struct {
		PackagesB64 []string `json:"packages_b64"`
		TTLSeconds  int      `json:"ttl_seconds"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	pkgs := make([][]byte, 0, len(body.PackagesB64))
	for _, b64 := range body.PackagesB64 {
		raw, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			http.Error(w, "invalid packages_b64", http.StatusBadRequest)
			return
		}
		pkgs = append(pkgs, raw)
	}
	var ttl time.Duration
	if body.TTLSeconds > 0 {
		ttl = time.Duration(body.TTLSeconds) * time.Second
	}
	if err := h.service.UploadKeyPackages(r.Context(), session.UserID, session.DeviceID, pkgs, ttl); err != nil {
		writeCryptoError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *CryptoHandler) ClaimKeyPackage(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	peerID, err := uuid.Parse(r.PathValue("userID"))
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}
	pkg, identity, err := h.service.ClaimKeyPackage(r.Context(), session.UserID, peerID)
	if err != nil {
		writeCryptoError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"package_id":        pkg.ID.String(),
		"device_id":         pkg.DeviceID.String(),
		"key_package_b64":   base64.StdEncoding.EncodeToString(pkg.KeyPackage),
		"fingerprint_hex":   identity.FingerprintHex,
		"public_key_b64":    base64.StdEncoding.EncodeToString(identity.PublicIdentityKey),
		"expires_at":        pkg.ExpiresAt.UTC(),
	})
}

func (h *CryptoHandler) PeerIdentities(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	peerID, err := uuid.Parse(r.PathValue("userID"))
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}
	ids, err := h.service.GetPeerIdentities(r.Context(), session.UserID, peerID)
	if err != nil {
		writeCryptoError(w, err)
		return
	}
	items := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		items = append(items, map[string]any{
			"device_id":        id.DeviceID.String(),
			"fingerprint_hex": id.FingerprintHex,
			"public_key_b64":  base64.StdEncoding.EncodeToString(id.PublicIdentityKey),
			"updated_at":      id.UpdatedAt.UTC(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"identities": items})
}

func (h *CryptoHandler) PoolStatus(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	n, need, err := h.service.PackagePoolStatus(r.Context(), session.UserID, session.DeviceID)
	if err != nil {
		writeCryptoError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available":        n,
		"needs_replenish":  need,
		"target_pool_size": crypto.TargetPackagePool,
	})
}

// RevokeCurrentDevice revokes MLS identity + key packages for the caller's device.
func (h *CryptoHandler) RevokeCurrentDevice(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	if err := h.service.RevokeDevice(r.Context(), session.UserID, session.DeviceID); err != nil {
		writeCryptoError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeCryptoError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, crypto.ErrInvalidInput):
		http.Error(w, "invalid input", http.StatusBadRequest)
	case errors.Is(err, crypto.ErrNotAuthorized):
		http.Error(w, "not authorized", http.StatusForbidden)
	case errors.Is(err, crypto.ErrIdentityMissing):
		http.Error(w, "identity not registered", http.StatusNotFound)
	case errors.Is(err, crypto.ErrIdentityMismatch):
		http.Error(w, "identity key mismatch", http.StatusConflict)
	case errors.Is(err, crypto.ErrIdentityRevoked), errors.Is(err, crypto.ErrDeviceRevoked):
		http.Error(w, "identity revoked", http.StatusForbidden)
	case errors.Is(err, crypto.ErrNoKeyPackage):
		http.Error(w, "no key package available", http.StatusNotFound)
	case errors.Is(err, crypto.ErrRateLimited):
		http.Error(w, "rate limited", http.StatusTooManyRequests)
	default:
		http.Error(w, "crypto error", http.StatusInternalServerError)
	}
}

// silence unused import if json used only via decodeExactJSON
var _ = json.Marshal
