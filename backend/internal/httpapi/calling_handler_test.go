package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/realtime"

	"github.com/google/uuid"
)

type callingAuth struct {
	session auth.AuthenticatedSession
}

func (c callingAuth) Authenticate(context.Context, string) (auth.AuthenticatedSession, error) {
	return c.session, nil
}

type callingFriends struct {
	ok bool
}

func (c callingFriends) AreAcceptedFriends(context.Context, uuid.UUID, uuid.UUID) (bool, error) {
	return c.ok, nil
}

type callingBlocks struct {
	blocked bool
}

func (c callingBlocks) IsBlockedEitherWay(context.Context, uuid.UUID, uuid.UUID) (bool, error) {
	return c.blocked, nil
}

func TestCallingHTTPHappyPathAndAuthz(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	store := calling.NewMemoryStore()
	svc := calling.NewService(store, callingFriends{ok: true}, callingBlocks{})
	hub := realtime.NewHub()
	handler := NewCallingHandler(svc, hub)
	svc.WithNotifier(handler)

	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: alice, DeviceID: aliceDev, ExpiresAt: time.Now().Add(time.Hour),
		}},
		CallingHandler: handler,
	})

	body, _ := json.Marshal(map[string]any{
		"callee_user_id": bob.String(),
		"media_type":     "audio",
		"client_call_id": "http-1",
	})
	req := httptest.NewRequest(http.MethodPost, "/calls", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("initiate want 201 got %d body=%s", rec.Code, rec.Body.String())
	}
	var created map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	callID := created["id"].(string)

	// Non-friend rejection
	svc2 := calling.NewService(calling.NewMemoryStore(), callingFriends{ok: false}, callingBlocks{})
	h2 := NewCallingHandler(svc2, realtime.NewHub())
	r2 := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: alice, DeviceID: aliceDev, ExpiresAt: time.Now().Add(time.Hour),
		}},
		CallingHandler: h2,
	})
	req2 := httptest.NewRequest(http.MethodPost, "/calls", bytes.NewReader(body))
	req2.Header.Set("Authorization", "Bearer tok")
	req2.Header.Set("Content-Type", "application/json")
	rec2 := httptest.NewRecorder()
	r2.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("nonfriend want 403 got %d", rec2.Code)
	}

	// Accept as bob
	bobRouter := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: bob, DeviceID: bobDev, ExpiresAt: time.Now().Add(time.Hour),
		}},
		CallingHandler: handler,
	})
	acc := httptest.NewRequest(http.MethodPost, "/calls/"+callID+"/accept", nil)
	acc.Header.Set("Authorization", "Bearer tok")
	accRec := httptest.NewRecorder()
	bobRouter.ServeHTTP(accRec, acc)
	if accRec.Code != http.StatusOK {
		t.Fatalf("accept want 200 got %d %s", accRec.Code, accRec.Body.String())
	}

	offerBody, _ := json.Marshal(map[string]string{"sdp": "v=0 offer"})
	off := httptest.NewRequest(http.MethodPut, "/calls/"+callID+"/offer", bytes.NewReader(offerBody))
	off.Header.Set("Authorization", "Bearer tok")
	off.Header.Set("Content-Type", "application/json")
	offRec := httptest.NewRecorder()
	router.ServeHTTP(offRec, off)
	if offRec.Code != http.StatusOK {
		t.Fatalf("offer want 200 got %d %s", offRec.Code, offRec.Body.String())
	}

	ansBody, _ := json.Marshal(map[string]string{"sdp": "v=0 answer"})
	ans := httptest.NewRequest(http.MethodPut, "/calls/"+callID+"/answer", bytes.NewReader(ansBody))
	ans.Header.Set("Authorization", "Bearer tok")
	ans.Header.Set("Content-Type", "application/json")
	ansRec := httptest.NewRecorder()
	bobRouter.ServeHTTP(ansRec, ans)
	if ansRec.Code != http.StatusOK {
		t.Fatalf("answer want 200 got %d %s", ansRec.Code, ansRec.Body.String())
	}

	hang := httptest.NewRequest(http.MethodPost, "/calls/"+callID+"/hangup", nil)
	hang.Header.Set("Authorization", "Bearer tok")
	hangRec := httptest.NewRecorder()
	router.ServeHTTP(hangRec, hang)
	if hangRec.Code != http.StatusOK {
		t.Fatalf("hangup want 200 got %d", hangRec.Code)
	}
}

func TestCallingRejectsOversizedSDP(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	aliceDev := uuid.New()
	store := calling.NewMemoryStore()
	svc := calling.NewService(store, callingFriends{ok: true}, callingBlocks{})
	handler := NewCallingHandler(svc, realtime.NewHub())
	res, err := svc.Initiate(context.Background(), alice, aliceDev, bob, calling.MediaAudio, "big")
	if err != nil {
		t.Fatal(err)
	}
	router := NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: callingAuth{session: auth.AuthenticatedSession{
			UserID: alice, DeviceID: aliceDev, ExpiresAt: time.Now().Add(time.Hour),
		}},
		CallingHandler: handler,
	})
	huge := make([]byte, calling.MaxSDPPChars+8)
	for i := range huge {
		huge[i] = 'x'
	}
	body, _ := json.Marshal(map[string]string{"sdp": string(huge)})
	req := httptest.NewRequest(http.MethodPut, "/calls/"+res.Session.ID.String()+"/offer", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413 got %d", rec.Code)
	}
}
