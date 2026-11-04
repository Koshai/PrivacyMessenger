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
	_ SessionAuthenticator,
	handler *RealtimeHandler,
) {
	mux.HandleFunc("GET /realtime/ws", handler.ServeWS)
}

func (h *RealtimeHandler) ServeWS(w http.ResponseWriter, r *http.Request) {
	// Reject query-string tokens explicitly (C3 security).
	if r.URL.Query().Get("access_token") != "" {
		http.Error(w, "access_token query parameter is not allowed", http.StatusBadRequest)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}

	ctx := r.Context()
	// Secure handshake: first client text frame must be {"type":"auth","token":"..."}.
	// No tokens in URLs or upgrade query strings.
	session, token, err := h.handshakeAuth(ctx, conn)
	if err != nil {
		_ = conn.Close(websocket.StatusPolicyViolation, "authentication required")
		return
	}

	hash := auth.HashSessionToken(token)
	tokenHash := string(hash[:])
	closed := make(chan string, 1)
	sub := h.hub.Subscribe(session.UserID, session.DeviceID, tokenHash, func(reason string) {
		select {
		case closed <- reason:
		default:
		}
	})
	defer h.hub.Unsubscribe(sub)

	hello, _ := json.Marshal(map[string]any{
		"type":      "connected",
		"device_id": session.DeviceID.String(),
		"user_id":   session.UserID.String(),
	})
	if err := conn.Write(ctx, websocket.MessageText, hello); err != nil {
		_ = conn.Close(websocket.StatusGoingAway, "write failed")
		return
	}

	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	reauth := time.NewTicker(30 * time.Second)
	defer reauth.Stop()

	for {
		select {
		case <-ctx.Done():
			_ = conn.Close(websocket.StatusGoingAway, "done")
			return
		case reason := <-closed:
			payload, _ := realtime.EncodeEvent(realtime.Event{Type: "session_revoked", Reason: reason})
			_ = conn.Write(ctx, websocket.MessageText, payload)
			_ = conn.Close(websocket.StatusPolicyViolation, reason)
			return
		case <-reauth.C:
			if _, err := h.auth.Authenticate(ctx, token); err != nil {
				payload, _ := realtime.EncodeEvent(realtime.Event{Type: "session_revoked", Reason: "invalid"})
				_ = conn.Write(ctx, websocket.MessageText, payload)
				_ = conn.Close(websocket.StatusPolicyViolation, "session revoked")
				return
			}
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

func (h *RealtimeHandler) handshakeAuth(
	ctx context.Context,
	conn *websocket.Conn,
) (auth.AuthenticatedSession, string, error) {
	readCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	msgType, data, err := conn.Read(readCtx)
	if err != nil {
		return auth.AuthenticatedSession{}, "", err
	}
	if msgType != websocket.MessageText {
		return auth.AuthenticatedSession{}, "", errors.New("expected text auth frame")
	}

	var body struct {
		Type  string `json:"type"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		return auth.AuthenticatedSession{}, "", err
	}
	if body.Type != "auth" || body.Token == "" {
		return auth.AuthenticatedSession{}, "", ErrInvalidAuthorization
	}
	if h.auth == nil {
		return auth.AuthenticatedSession{}, "", errors.New("auth unavailable")
	}
	session, err := h.auth.Authenticate(ctx, body.Token)
	if err != nil {
		return auth.AuthenticatedSession{}, "", err
	}
	return session, body.Token, nil
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

func (h *RealtimeHandler) DisconnectToken(token string, reason string) {
	if h == nil || h.hub == nil {
		return
	}
	sum := auth.HashSessionToken(token)
	h.hub.DisconnectToken(string(sum[:]), reason)
}

func (h *RealtimeHandler) DisconnectUser(userID uuid.UUID, reason string) {
	if h == nil || h.hub == nil {
		return
	}
	h.hub.DisconnectUser(userID, reason)
}
