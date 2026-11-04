package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
)

type fakeMessagingService struct {
	sendResult messaging.SendResult
	sendErr    error
	history    []messaging.Envelope
	historyErr error
}

func (f *fakeMessagingService) OpenConversation(context.Context, uuid.UUID, uuid.UUID) (messaging.Conversation, error) {
	return messaging.Conversation{ID: uuid.New(), CreatedAt: time.Now().UTC()}, nil
}
func (f *fakeMessagingService) SendEnvelope(context.Context, uuid.UUID, uuid.UUID, string, []byte, string) (messaging.SendResult, error) {
	return f.sendResult, f.sendErr
}
func (f *fakeMessagingService) ListHistory(context.Context, uuid.UUID, uuid.UUID, *messaging.PageCursor, int) ([]messaging.Envelope, error) {
	return f.history, f.historyErr
}
func (f *fakeMessagingService) Acknowledge(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (f *fakeMessagingService) SyncPending(context.Context, uuid.UUID, int) ([]messaging.Envelope, error) {
	return nil, nil
}

func TestSendEnvelopeRejectsNonBase64Ciphertext(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{
			session: auth.AuthenticatedSession{
				UserID:    uuid.New(),
				DeviceID:  uuid.New(),
				ExpiresAt: time.Now().Add(time.Hour),
			},
		},
		MessagingHandler: NewMessagingHandler(&fakeMessagingService{}),
	})

	body := `{"client_message_id":"m1","ciphertext_b64":"%%%","content_type":"application/opaque"}`
	req := httptest.NewRequest(http.MethodPost, "/conversations/"+uuid.New().String()+"/envelopes", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestSendEnvelopeReturnsOpaquePayload(t *testing.T) {
	envelopeID := uuid.New()
	conversationID := uuid.New()
	ciphertext := []byte{0xde, 0xad}
	svc := &fakeMessagingService{
		sendResult: messaging.SendResult{
			Created: true,
			Envelope: messaging.Envelope{
				ID:              envelopeID,
				ConversationID:  conversationID,
				SenderID:        uuid.New(),
				ClientMessageID: "m1",
				Ciphertext:      ciphertext,
				ContentType:     "application/opaque",
				CreatedAt:       time.Now().UTC(),
			},
		},
	}

	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{
			session: auth.AuthenticatedSession{
				UserID:    uuid.New(),
				DeviceID:  uuid.New(),
				ExpiresAt: time.Now().Add(time.Hour),
			},
		},
		MessagingHandler: NewMessagingHandler(svc),
	})

	body := `{"client_message_id":"m1","ciphertext_b64":"` + base64.StdEncoding.EncodeToString(ciphertext) + `","content_type":"application/opaque"}`
	req := httptest.NewRequest(http.MethodPost, "/conversations/"+conversationID.String()+"/envelopes", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["ciphertext_b64"] != base64.StdEncoding.EncodeToString(ciphertext) {
		t.Fatalf("server must round-trip opaque bytes, got %#v", payload)
	}
}

func TestListHistoryUnauthorizedMapped(t *testing.T) {
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: fakeSessionAuthenticator{
			session: auth.AuthenticatedSession{
				UserID:    uuid.New(),
				DeviceID:  uuid.New(),
				ExpiresAt: time.Now().Add(time.Hour),
			},
		},
		MessagingHandler: NewMessagingHandler(&fakeMessagingService{
			historyErr: messaging.ErrNotAuthorized,
		}),
	})

	req := httptest.NewRequest(http.MethodGet, "/conversations/"+uuid.New().String()+"/envelopes", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
