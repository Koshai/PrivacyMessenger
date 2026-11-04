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
	"example.com/private-messenger/backend/internal/friends"

	"github.com/google/uuid"
)

type fakeFriendsService struct {
	requestErr error
	acceptErr  error
	rejectErr  error
	list       []friends.FriendSummary
	count      int
	incoming   []friends.PendingRequest
}

func (f *fakeFriendsService) RequestByEmail(context.Context, uuid.UUID, string) error {
	return f.requestErr
}
func (f *fakeFriendsService) Accept(context.Context, uuid.UUID, uuid.UUID) error {
	return f.acceptErr
}
func (f *fakeFriendsService) Reject(context.Context, uuid.UUID, uuid.UUID) error {
	return f.rejectErr
}
func (f *fakeFriendsService) RemoveFriend(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (f *fakeFriendsService) ListFriends(context.Context, uuid.UUID) ([]friends.FriendSummary, error) {
	return f.list, nil
}
func (f *fakeFriendsService) FriendCount(context.Context, uuid.UUID) (int, error) {
	return f.count, nil
}
func (f *fakeFriendsService) ListIncoming(context.Context, uuid.UUID) ([]friends.PendingRequest, error) {
	return f.incoming, nil
}
func (f *fakeFriendsService) ListOutgoing(context.Context, uuid.UUID) ([]friends.PendingRequest, error) {
	return nil, nil
}
func (f *fakeFriendsService) BlockByUserID(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (f *fakeFriendsService) Unblock(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (f *fakeFriendsService) ListBlocked(context.Context, uuid.UUID) ([]friends.BlockRecord, error) {
	return nil, nil
}

func friendsRouter(service FriendsService, authenticator SessionAuthenticator) http.Handler {
	return NewConfiguredRouter(RouterDependencies{
		SessionAuthenticator: authenticator,
		FriendsHandler:       NewFriendsHandler(service),
	})
}

func TestCreateFriendRequestRequiresAuth(t *testing.T) {
	router := friendsRouter(&fakeFriendsService{}, fakeSessionAuthenticator{
		err: auth.ErrInvalidSession,
	})

	req := httptest.NewRequest(http.MethodPost, "/friends/requests", strings.NewReader(`{"email":"a@b.com"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestCreateFriendRequestAccepted(t *testing.T) {
	userID := uuid.New()
	router := friendsRouter(&fakeFriendsService{}, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    userID,
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})

	req := httptest.NewRequest(http.MethodPost, "/friends/requests", strings.NewReader(`{"email":"friend@example.com"}`))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCreateFriendRequestMapsDomainErrors(t *testing.T) {
	userID := uuid.New()
	router := friendsRouter(&fakeFriendsService{requestErr: friends.ErrSelfRelationship}, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    userID,
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})

	req := httptest.NewRequest(http.MethodPost, "/friends/requests", strings.NewReader(`{"email":"me@example.com"}`))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestListFriendsReturnsPrivatePayload(t *testing.T) {
	friendID := uuid.New()
	router := friendsRouter(&fakeFriendsService{
		list: []friends.FriendSummary{{
			UserID: friendID,
			Email:  "friend@example.com",
			Since:  time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC),
		}},
		count: 1,
	}, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    uuid.New(),
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})

	req := httptest.NewRequest(http.MethodGet, "/friends", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	friendsList, ok := body["friends"].([]any)
	if !ok || len(friendsList) != 1 {
		t.Fatalf("unexpected friends payload: %#v", body)
	}
}

func TestAcceptFriendRequestRoute(t *testing.T) {
	requestID := uuid.New()
	router := friendsRouter(&fakeFriendsService{}, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    uuid.New(),
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})

	req := httptest.NewRequest(http.MethodPost, "/friends/requests/"+requestID.String()+"/accept", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
}

func TestUnauthorizedAcceptMappedToNotFound(t *testing.T) {
	requestID := uuid.New()
	router := friendsRouter(&fakeFriendsService{acceptErr: friends.ErrRequestNotFound}, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    uuid.New(),
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})

	req := httptest.NewRequest(http.MethodPost, "/friends/requests/"+requestID.String()+"/accept", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}
