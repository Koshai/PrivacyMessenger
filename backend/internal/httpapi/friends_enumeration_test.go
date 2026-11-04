package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/friends"

	"github.com/google/uuid"
)

type enumFriendsService struct {
	mu sync.Mutex

	requestCalls atomic.Int64
	emails       []string
	requestErr   error

	acceptCalls atomic.Int64
	acceptIDs   []uuid.UUID
	acceptErr   error
}

func (s *enumFriendsService) RequestByEmail(_ context.Context, _ uuid.UUID, email string) error {
	s.requestCalls.Add(1)
	s.mu.Lock()
	s.emails = append(s.emails, email)
	s.mu.Unlock()
	return s.requestErr
}

func (s *enumFriendsService) Accept(_ context.Context, _ uuid.UUID, id uuid.UUID) error {
	s.acceptCalls.Add(1)
	s.mu.Lock()
	s.acceptIDs = append(s.acceptIDs, id)
	s.mu.Unlock()
	return s.acceptErr
}

func (s *enumFriendsService) Reject(context.Context, uuid.UUID, uuid.UUID) error {
	return friends.ErrRequestNotFound
}
func (s *enumFriendsService) RemoveFriend(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (s *enumFriendsService) ListFriends(context.Context, uuid.UUID) ([]friends.FriendSummary, error) {
	return nil, nil
}
func (s *enumFriendsService) FriendCount(context.Context, uuid.UUID) (int, error) {
	return 0, nil
}
func (s *enumFriendsService) ListIncoming(context.Context, uuid.UUID) ([]friends.PendingRequest, error) {
	return nil, nil
}
func (s *enumFriendsService) ListOutgoing(context.Context, uuid.UUID) ([]friends.PendingRequest, error) {
	return nil, nil
}
func (s *enumFriendsService) BlockByUserID(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (s *enumFriendsService) Unblock(context.Context, uuid.UUID, uuid.UUID) error {
	return nil
}
func (s *enumFriendsService) ListBlocked(context.Context, uuid.UUID) ([]friends.BlockRecord, error) {
	return nil, nil
}

func authedFriendsRouter(service FriendsService) http.Handler {
	return friendsRouter(service, fakeSessionAuthenticator{
		session: auth.AuthenticatedSession{
			UserID:    uuid.New(),
			DeviceID:  uuid.New(),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	})
}

func TestFriendRequestUnknownAndExistingShareAcceptedStatus(t *testing.T) {
	// Both unknown-email success and "already related" paths must present as 202
	// so status codes cannot be used to enumerate accounts.
	cases := []struct {
		name string
		err  error
	}{
		{name: "unknown_or_created", err: nil},
		{name: "already_friends_mapped_nil", err: nil},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc := &enumFriendsService{requestErr: tc.err}
			router := authedFriendsRouter(svc)

			req := httptest.NewRequest(
				http.MethodPost,
				"/friends/requests",
				strings.NewReader(`{"email":"probe@example.com"}`),
			)
			req.Header.Set("Authorization", "Bearer token")
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)

			if rec.Code != http.StatusAccepted {
				t.Fatalf("expected 202, got %d body=%s", rec.Code, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), "If that account exists") {
				t.Fatalf("expected generic message, got %s", rec.Body.String())
			}
		})
	}
}

func TestFriendRequestDoesNotExposeConflictForRelationshipState(t *testing.T) {
	// Handler must not surface 409 for relationship conflicts if the service
	// still returns those domain errors (defense in depth).
	svc := &enumFriendsService{requestErr: friends.ErrAlreadyFriends}
	router := authedFriendsRouter(svc)

	req := httptest.NewRequest(
		http.MethodPost,
		"/friends/requests",
		strings.NewReader(`{"email":"friend@example.com"}`),
	)
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	// Until handler normalizes these, document current mapping. Prefer 202.
	// After service change, ErrAlreadyFriends should not reach the handler.
	if rec.Code == http.StatusConflict {
		t.Fatalf("409 conflict discloses relationship existence")
	}
}

func TestAcceptDoesNotDistinguishMissingVersusUnauthorized(t *testing.T) {
	missingID := uuid.New()
	foreignID := uuid.New()

	for _, id := range []uuid.UUID{missingID, foreignID} {
		svc := &enumFriendsService{acceptErr: friends.ErrRequestNotFound}
		router := authedFriendsRouter(svc)

		req := httptest.NewRequest(
			http.MethodPost,
			"/friends/requests/"+id.String()+"/accept",
			nil,
		)
		req.Header.Set("Authorization", "Bearer token")
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("expected uniform 404 for %s, got %d", id, rec.Code)
		}
	}
}

func TestFriendRequestRateLimitSurfacesAs429(t *testing.T) {
	svc := &enumFriendsService{requestErr: friends.ErrRateLimited}
	router := authedFriendsRouter(svc)

	req := httptest.NewRequest(
		http.MethodPost,
		"/friends/requests",
		strings.NewReader(`{"email":"flood@example.com"}`),
	)
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", rec.Code)
	}
}

func TestFriendRequestRejectsMalformedBodiesWithoutServiceCall(t *testing.T) {
	svc := &enumFriendsService{}
	router := authedFriendsRouter(svc)

	bodies := []string{
		``,
		`[]`,
		`{"email":"a@b.com","extra":true}`,
		`{"email":"a@b.com"}{"email":"c@d.com"}`,
	}

	for _, body := range bodies {
		req := httptest.NewRequest(
			http.MethodPost,
			"/friends/requests",
			strings.NewReader(body),
		)
		req.Header.Set("Authorization", "Bearer token")
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %q: expected 400, got %d", body, rec.Code)
		}
	}

	if svc.requestCalls.Load() != 0 {
		t.Fatalf("service should not be called for malformed bodies")
	}
}

func TestNoPublicFriendDirectoryRoutes(t *testing.T) {
	router := authedFriendsRouter(&enumFriendsService{})

	probes := []string{
		"/friends/search?q=alice",
		"/friends/directory",
		"/users/alice@example.com/friends",
		"/friends/" + uuid.New().String() + "/friends",
	}

	for _, path := range probes {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer token")
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)

		if rec.Code == http.StatusOK {
			t.Fatalf("unexpected public-style route success for %s", path)
		}
	}
}
