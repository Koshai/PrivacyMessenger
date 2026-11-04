package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/realtime"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

type RealtimeHandler struct {
	hub  *realtime.Hub
	auth SessionAuthenticator
}

func NewRealtimeHandler(hub *realtime.Hub, authenticator SessionAuthenticator) *RealtimeHandler {
	return &RealtimeHandler{hub: hub, auth: authenticator}
}

func RegisterRealtimeRoutes(
	mux *http.ServeMux,
	auth SessionAuthenticator,
	handler *RealtimeHandler,
) {
	// Auth is performed inside ServeWS so WebSocket clients may pass
	// access_token as a query parameter when headers are unavailable.
	_ = auth
	mux.HandleFunc("GET /realtime/ws", handler.ServeWS)
}

func (h *RealtimeHandler) ServeWS(w http.ResponseWriter, r *http.Request) {
	session, err := h.authenticateWS(r)
	if err != nil {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "bye")

	sub := h.hub.Subscribe(session.UserID)
	defer h.hub.Unsubscribe(sub)

	ctx := r.Context()
	hello, _ := json.Marshal(map[string]any{
		"type":      "connected",
		"device_id": session.DeviceID.String(),
		"user_id":   session.UserID.String(),
	})
	_ = conn.Write(ctx, websocket.MessageText, hello)

	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ping.C:
			pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				return
			}
		case event, ok := <-sub.Events():
			if !ok {
				return
			}
			payload, err := realtime.EncodeEvent(event)
			if err != nil {
				continue
			}
			writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err = conn.Write(writeCtx, websocket.MessageText, payload)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (h *RealtimeHandler) authenticateWS(r *http.Request) (auth.AuthenticatedSession, error) {
	token, err := ParseBearerToken(r.Header)
	if err != nil {
		token = r.URL.Query().Get("access_token")
		if token == "" {
			return auth.AuthenticatedSession{}, ErrInvalidAuthorization
		}
	}
	if h.auth == nil {
		return auth.AuthenticatedSession{}, errors.New("auth unavailable")
	}
	return h.auth.Authenticate(r.Context(), token)
}

func (h *RealtimeHandler) NotifyEnvelope(recipientID, conversationID, envelopeID uuid.UUID) {
	if h == nil || h.hub == nil {
		return
	}
	h.hub.NotifyUser(recipientID, realtime.Event{
		Type:           "envelope",
		EnvelopeID:     envelopeID.String(),
		ConversationID: conversationID.String(),
		Cursor:         envelopeID.String(),
	})
}
