package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
)

type MessagingService interface {
	OpenConversation(ctx context.Context, actorID, peerID uuid.UUID) (messaging.Conversation, error)
	EstablishMlsGroup(ctx context.Context, actorID, conversationID uuid.UUID, groupIDHex string) (messaging.Conversation, error)
	SendEnvelope(ctx context.Context, actorID, conversationID uuid.UUID, clientMessageID string, ciphertext []byte, contentType string) (messaging.SendResult, error)
	ListHistory(ctx context.Context, actorID, conversationID uuid.UUID, before *messaging.PageCursor, limit int) ([]messaging.Envelope, error)
	Acknowledge(ctx context.Context, actorID, envelopeID uuid.UUID) error
	SyncPending(ctx context.Context, actorID uuid.UUID, limit int) ([]messaging.Envelope, error)
}

type MessagingHandler struct {
	service MessagingService
}

func NewMessagingHandler(service MessagingService) *MessagingHandler {
	return &MessagingHandler{service: service}
}

type openConversationBody struct {
	PeerUserID string `json:"peer_user_id"`
}

type sendEnvelopeBody struct {
	ClientMessageID string `json:"client_message_id"`
	CiphertextB64   string `json:"ciphertext_b64"`
	ContentType     string `json:"content_type"`
}

func (h *MessagingHandler) OpenConversation(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	var body openConversationBody
	if !decodeExactJSON(w, r, &body) {
		return
	}
	peerID, err := uuid.Parse(body.PeerUserID)
	if err != nil {
		http.Error(w, "invalid peer_user_id", http.StatusBadRequest)
		return
	}

	conversation, err := h.service.OpenConversation(r.Context(), session.UserID, peerID)
	if err != nil {
		writeMessagingError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, mapConversation(conversation))
}

func (h *MessagingHandler) EstablishMlsGroup(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	conversationID, err := uuid.Parse(r.PathValue("conversationID"))
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}
	var body struct {
		MlsGroupIDHex string `json:"mls_group_id_hex"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	conversation, err := h.service.EstablishMlsGroup(
		r.Context(), session.UserID, conversationID, body.MlsGroupIDHex,
	)
	if err != nil {
		writeMessagingError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, mapConversation(conversation))
}

func (h *MessagingHandler) SendEnvelope(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	conversationID, err := uuid.Parse(r.PathValue("conversationID"))
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}

	var body sendEnvelopeBody
	if !decodeExactJSON(w, r, &body) {
		return
	}

	ciphertext, err := base64.StdEncoding.DecodeString(body.CiphertextB64)
	if err != nil {
		http.Error(w, "invalid ciphertext_b64", http.StatusBadRequest)
		return
	}

	result, err := h.service.SendEnvelope(
		r.Context(),
		session.UserID,
		conversationID,
		body.ClientMessageID,
		ciphertext,
		body.ContentType,
	)
	if err != nil {
		writeMessagingError(w, err)
		return
	}

	status := http.StatusCreated
	if !result.Created {
		status = http.StatusOK
	}
	writeJSON(w, status, mapEnvelope(result.Envelope))
}

func (h *MessagingHandler) ListHistory(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	conversationID, err := uuid.Parse(r.PathValue("conversationID"))
	if err != nil {
		http.Error(w, "invalid conversation id", http.StatusBadRequest)
		return
	}

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	var before *messaging.PageCursor
	if beforeID := r.URL.Query().Get("before_id"); beforeID != "" {
		id, err := uuid.Parse(beforeID)
		if err != nil {
			http.Error(w, "invalid before_id", http.StatusBadRequest)
			return
		}
		beforeAt, err := time.Parse(time.RFC3339Nano, r.URL.Query().Get("before_created_at"))
		if err != nil {
			http.Error(w, "invalid before_created_at", http.StatusBadRequest)
			return
		}
		before = &messaging.PageCursor{ID: id, CreatedAt: beforeAt.UTC()}
	}

	items, err := h.service.ListHistory(r.Context(), session.UserID, conversationID, before, limit)
	if err != nil {
		writeMessagingError(w, err)
		return
	}

	payload := make([]map[string]any, 0, len(items))
	for _, item := range items {
		payload = append(payload, mapEnvelope(item))
	}
	writeJSON(w, http.StatusOK, map[string]any{"envelopes": payload})
}

func (h *MessagingHandler) Acknowledge(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	envelopeID, err := uuid.Parse(r.PathValue("envelopeID"))
	if err != nil {
		http.Error(w, "invalid envelope id", http.StatusBadRequest)
		return
	}
	if err := h.service.Acknowledge(r.Context(), session.UserID, envelopeID); err != nil {
		writeMessagingError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *MessagingHandler) SyncPending(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	items, err := h.service.SyncPending(r.Context(), session.UserID, limit)
	if err != nil {
		writeMessagingError(w, err)
		return
	}
	payload := make([]map[string]any, 0, len(items))
	for _, item := range items {
		payload = append(payload, mapEnvelope(item))
	}
	writeJSON(w, http.StatusOK, map[string]any{"envelopes": payload})
}

func mapConversation(c messaging.Conversation) map[string]any {
	out := map[string]any{
		"conversation_id": c.ID.String(),
		"created_at":      c.CreatedAt.UTC(),
	}
	if c.MlsGroupIDHex != nil {
		out["mls_group_id_hex"] = *c.MlsGroupIDHex
	}
	if c.MlsInitiatorID != nil {
		out["mls_initiator_id"] = c.MlsInitiatorID.String()
	}
	if c.MlsEstablishedAt != nil {
		out["mls_established_at"] = c.MlsEstablishedAt.UTC()
	}
	return out
}

func mapEnvelope(e messaging.Envelope) map[string]any {
	return map[string]any{
		"id":                e.ID.String(),
		"conversation_id":   e.ConversationID.String(),
		"sender_id":         e.SenderID.String(),
		"client_message_id": e.ClientMessageID,
		"ciphertext_b64":    base64.StdEncoding.EncodeToString(e.Ciphertext),
		"content_type":      e.ContentType,
		"created_at":        e.CreatedAt.UTC(),
	}
}

func decodeExactJSON(w http.ResponseWriter, r *http.Request, dest any) bool {
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dest); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return false
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(w, "request must contain exactly one JSON object", http.StatusBadRequest)
		return false
	}
	return true
}

func writeMessagingError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, messaging.ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case errors.Is(err, messaging.ErrNotAuthorized),
		errors.Is(err, messaging.ErrNotFriends):
		http.Error(w, err.Error(), http.StatusForbidden)
	case errors.Is(err, messaging.ErrConversationMissing),
		errors.Is(err, messaging.ErrEnvelopeMissing):
		http.Error(w, err.Error(), http.StatusNotFound)
	case errors.Is(err, messaging.ErrMlsNotEstablished):
		http.Error(w, err.Error(), http.StatusConflict)
	case errors.Is(err, messaging.ErrMlsAlreadySet),
		errors.Is(err, messaging.ErrMlsGroupMismatch):
		http.Error(w, err.Error(), http.StatusConflict)
	default:
		http.Error(w, "messaging operation failed", http.StatusInternalServerError)
	}
}
