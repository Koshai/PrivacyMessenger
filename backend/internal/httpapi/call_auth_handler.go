package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"

	"example.com/private-messenger/backend/internal/callauth"
	"example.com/private-messenger/backend/internal/calling"

	"github.com/google/uuid"
)

type callAuthAPI interface {
	RegisterKey(ctx context.Context, userID, deviceID uuid.UUID, publicKey []byte) error
	Submit(ctx context.Context, in callauth.SubmitInput) (callauth.Frame, error)
	List(ctx context.Context, actor, callID uuid.UUID) ([]callauth.Frame, error)
}

type CallAuthHandler struct{ service callAuthAPI }

func NewCallAuthHandler(service callAuthAPI) *CallAuthHandler {
	return &CallAuthHandler{service: service}
}

func (h *CallAuthHandler) RegisterKey(w http.ResponseWriter, r *http.Request) {
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
	key, err := base64.StdEncoding.DecodeString(body.PublicKeyB64)
	if err != nil {
		http.Error(w, "invalid public key", http.StatusBadRequest)
		return
	}
	if err := h.service.RegisterKey(r.Context(), session.UserID, session.DeviceID, key); err != nil {
		writeCallAuthError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *CallAuthHandler) Submit(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	var body struct {
		Kind          string `json:"kind"`
		ClientAuthID  string `json:"client_auth_id"`
		NonceB64      string `json:"nonce_b64"`
		CallKeyB64    string `json:"call_public_key_b64"`
		MLSHex        string `json:"mls_fingerprint_hex"`
		DTLSLocalB64  string `json:"dtls_local_b64"`
		DTLSRemoteB64 string `json:"dtls_remote_b64"`
		SignatureB64  string `json:"signature_b64"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	in := callauth.SubmitInput{
		CallID: callID, ActorUser: session.UserID, ActorDevice: session.DeviceID,
		Kind: body.Kind, ClientAuthID: body.ClientAuthID,
		Nonce: mustB64(body.NonceB64), CallKey: mustB64(body.CallKeyB64),
		MLS: mustHex(body.MLSHex), Signature: mustB64(body.SignatureB64),
		DTLSLocal: mustB64(body.DTLSLocalB64), DTLSRemote: mustB64(body.DTLSRemoteB64),
	}
	frame, err := h.service.Submit(r.Context(), in)
	if err != nil {
		writeCallAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, mapAuthFrame(frame))
}

func (h *CallAuthHandler) List(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	frames, err := h.service.List(r.Context(), session.UserID, callID)
	if err != nil {
		writeCallAuthError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(frames))
	for _, f := range frames {
		out = append(out, mapAuthFrame(f))
	}
	writeJSON(w, http.StatusOK, map[string]any{"frames": out})
}

func mapAuthFrame(f callauth.Frame) map[string]any {
	return map[string]any{
		"kind": f.Kind, "client_auth_id": f.ClientAuthID,
		"sender_user_id": f.SenderUser.String(), "sender_device_id": f.SenderDevice.String(),
		"nonce_b64": b64(f.Nonce), "call_public_key_b64": b64(f.CallKey),
		"mls_fingerprint_hex": hexEncode(f.MLS),
		"dtls_local_b64":      b64(f.DTLSLocal), "dtls_remote_b64": b64(f.DTLSRemote),
		"signature_b64": b64(f.Signature),
	}
}

func writeCallAuthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, callauth.ErrReplay):
		http.Error(w, "replayed handshake", http.StatusConflict)
	case errors.Is(err, callauth.ErrRevoked):
		http.Error(w, "identity revoked", http.StatusForbidden)
	case errors.Is(err, callauth.ErrNotReady):
		http.Error(w, "handshake not ready", http.StatusConflict)
	case errors.Is(err, calling.ErrCallMissing):
		http.Error(w, "call not available", http.StatusNotFound)
	case errors.Is(err, callauth.ErrMismatch), errors.Is(err, callauth.ErrInvalid):
		http.Error(w, "handshake rejected", http.StatusBadRequest)
	default:
		http.Error(w, "handshake rejected", http.StatusBadRequest)
	}
}

func b64(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

func mustB64(s string) []byte {
	if s == "" {
		return nil
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return []byte{0}
	}
	return b
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 {
		return []byte{0}
	}
	return b
}

func hexEncode(b []byte) string { return hex.EncodeToString(b) }
