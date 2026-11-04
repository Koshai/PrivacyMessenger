package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/realtime"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

func TestRealtimeRejectsOversizedAuthFrame(t *testing.T) {
	hub := realtime.NewHub()
	authenticator := &fakeWSAuth{
		session: auth.AuthenticatedSession{
			UserID:    uuid.New(),
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	}
	handler := NewRealtimeHandler(hub, authenticator)
	server := httptest.NewServer(http.HandlerFunc(handler.ServeWS))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	huge := strings.Repeat("a", wsAuthFrameMaxBytes+64)
	frame, _ := json.Marshal(map[string]string{"type": "auth", "token": huge})
	if err := conn.Write(ctx, websocket.MessageText, frame); err != nil {
		t.Fatal(err)
	}

	_, _, err = conn.Read(ctx)
	if err == nil {
		t.Fatal("expected handshake failure / close for oversized auth frame")
	}
}
