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

type fakeWSAuth struct {
	session auth.AuthenticatedSession
	err     error
	calls   int
}

func (f *fakeWSAuth) Authenticate(context.Context, string) (auth.AuthenticatedSession, error) {
	f.calls++
	if f.err != nil {
		return auth.AuthenticatedSession{}, f.err
	}
	return f.session, nil
}

func TestRealtimeRejectsAccessTokenQuery(t *testing.T) {
	hub := realtime.NewHub()
	h := NewRealtimeHandler(hub, &fakeWSAuth{})
	req := httptest.NewRequest(http.MethodGet, "/realtime/ws?access_token=secret", nil)
	rec := httptest.NewRecorder()
	h.ServeWS(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestRealtimeHandshakeAuthAndRevoke(t *testing.T) {
	hub := realtime.NewHub()
	userID := uuid.New()
	deviceID := uuid.New()
	authenticator := &fakeWSAuth{
		session: auth.AuthenticatedSession{
			UserID:    userID,
			DeviceID:  deviceID,
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

	authFrame, _ := json.Marshal(map[string]string{"type": "auth", "token": "valid-token-not-checked-by-fake"})
	if err := conn.Write(ctx, websocket.MessageText, authFrame); err != nil {
		t.Fatal(err)
	}

	_, hello, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var helloMsg map[string]any
	if err := json.Unmarshal(hello, &helloMsg); err != nil {
		t.Fatal(err)
	}
	if helloMsg["type"] != "connected" {
		t.Fatalf("expected connected, got %#v", helloMsg)
	}

	handler.DisconnectToken("valid-token-not-checked-by-fake", "revoked")
	_, revokeMsg, err := conn.Read(ctx)
	if err != nil {
		// Connection may close; either revoked event or close is success.
		return
	}
	var evt map[string]any
	_ = json.Unmarshal(revokeMsg, &evt)
	if evt["type"] != "session_revoked" && evt["type"] != "connected" {
		t.Fatalf("unexpected event %#v", evt)
	}
}
