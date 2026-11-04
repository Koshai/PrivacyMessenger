package friends

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

type memoryLimiter struct {
	mu       sync.Mutex
	counts   map[uuid.UUID]int
	limit    int
	failNext bool
}

func newMemoryLimiter(limit int) *memoryLimiter {
	return &memoryLimiter{counts: map[uuid.UUID]int{}, limit: limit}
}

func (l *memoryLimiter) AllowRequest(_ context.Context, requesterID uuid.UUID) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.failNext {
		return ErrRateLimited
	}
	l.counts[requesterID]++
	if l.counts[requesterID] > l.limit {
		return ErrRateLimited
	}
	return nil
}

type memoryStore struct {
	mu           sync.Mutex
	usersByEmail map[string]uuid.UUID
	friendships  map[uuid.UUID]Friendship
	blocks       map[[2]uuid.UUID]bool
}

func newMemoryStore() *memoryStore {
	return &memoryStore{
		usersByEmail: map[string]uuid.UUID{},
		friendships:  map[uuid.UUID]Friendship{},
		blocks:       map[[2]uuid.UUID]bool{},
	}
}

func (s *memoryStore) addUser(email string, id uuid.UUID) {
	s.usersByEmail[email] = id
}

func (s *memoryStore) FindActiveUserIDByEmail(_ context.Context, emailNormalized string) (uuid.UUID, error) {
	id, ok := s.usersByEmail[emailNormalized]
	if !ok {
		return uuid.Nil, ErrUserUnavailable
	}
	return id, nil
}

func (s *memoryStore) IsBlockedEitherWay(_ context.Context, userA, userB uuid.UUID) (bool, error) {
	return s.blocks[[2]uuid.UUID{userA, userB}] || s.blocks[[2]uuid.UUID{userB, userA}], nil
}

func (s *memoryStore) FindAcceptedBetween(_ context.Context, userA, userB uuid.UUID) (*Friendship, error) {
	for _, f := range s.friendships {
		if f.Status != StatusAccepted {
			continue
		}
		if (f.RequesterID == userA && f.AddresseeID == userB) ||
			(f.RequesterID == userB && f.AddresseeID == userA) {
			copy := f
			return &copy, nil
		}
	}
	return nil, nil
}

func (s *memoryStore) FindPendingBetween(_ context.Context, userA, userB uuid.UUID) (*Friendship, error) {
	for _, f := range s.friendships {
		if f.Status != StatusPending {
			continue
		}
		if (f.RequesterID == userA && f.AddresseeID == userB) ||
			(f.RequesterID == userB && f.AddresseeID == userA) {
			copy := f
			return &copy, nil
		}
	}
	return nil, nil
}

func (s *memoryStore) CreatePending(_ context.Context, requesterID, addresseeID uuid.UUID) (Friendship, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, f := range s.friendships {
		if f.Status == StatusPending && f.RequesterID == requesterID && f.AddresseeID == addresseeID {
			return Friendship{}, ErrRequestAlreadyPending
		}
	}
	f := Friendship{
		ID:          uuid.New(),
		RequesterID: requesterID,
		AddresseeID: addresseeID,
		Status:      StatusPending,
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   time.Now().UTC(),
	}
	s.friendships[f.ID] = f
	return f, nil
}

func (s *memoryStore) GetByID(_ context.Context, id uuid.UUID) (Friendship, error) {
	f, ok := s.friendships[id]
	if !ok {
		return Friendship{}, ErrRequestNotFound
	}
	return f, nil
}

func (s *memoryStore) UpdateStatus(_ context.Context, id uuid.UUID, status Status) error {
	f, ok := s.friendships[id]
	if !ok {
		return ErrRequestNotFound
	}
	f.Status = status
	f.UpdatedAt = time.Now().UTC()
	s.friendships[id] = f
	return nil
}

func (s *memoryStore) DeleteByID(_ context.Context, id uuid.UUID) error {
	if _, ok := s.friendships[id]; !ok {
		return ErrNotFriends
	}
	delete(s.friendships, id)
	return nil
}

func (s *memoryStore) ListAccepted(_ context.Context, userID uuid.UUID) ([]FriendSummary, error) {
	var out []FriendSummary
	for _, f := range s.friendships {
		if f.Status != StatusAccepted {
			continue
		}
		if f.RequesterID != userID && f.AddresseeID != userID {
			continue
		}
		friendID := f.AddresseeID
		if f.AddresseeID == userID {
			friendID = f.RequesterID
		}
		out = append(out, FriendSummary{UserID: friendID, Email: friendID.String(), Since: f.UpdatedAt})
	}
	return out, nil
}

func (s *memoryStore) CountAccepted(ctx context.Context, userID uuid.UUID) (int, error) {
	items, err := s.ListAccepted(ctx, userID)
	return len(items), err
}

func (s *memoryStore) ListIncomingPending(_ context.Context, userID uuid.UUID) ([]PendingRequest, error) {
	var out []PendingRequest
	for _, f := range s.friendships {
		if f.Status == StatusPending && f.AddresseeID == userID {
			out = append(out, PendingRequest{ID: f.ID, UserID: f.RequesterID, Email: f.RequesterID.String()})
		}
	}
	return out, nil
}

func (s *memoryStore) ListOutgoingPending(_ context.Context, userID uuid.UUID) ([]PendingRequest, error) {
	var out []PendingRequest
	for _, f := range s.friendships {
		if f.Status == StatusPending && f.RequesterID == userID {
			out = append(out, PendingRequest{ID: f.ID, UserID: f.AddresseeID, Email: f.AddresseeID.String(), Outgoing: true})
		}
	}
	return out, nil
}

func (s *memoryStore) CreateBlock(_ context.Context, blockerID, blockedID uuid.UUID) error {
	s.blocks[[2]uuid.UUID{blockerID, blockedID}] = true
	return nil
}

func (s *memoryStore) DeleteBlock(_ context.Context, blockerID, blockedID uuid.UUID) error {
	delete(s.blocks, [2]uuid.UUID{blockerID, blockedID})
	return nil
}

func (s *memoryStore) ListBlocks(_ context.Context, blockerID uuid.UUID) ([]BlockRecord, error) {
	var out []BlockRecord
	for key := range s.blocks {
		if key[0] == blockerID {
			out = append(out, BlockRecord{BlockedUserID: key[1], Email: key[1].String()})
		}
	}
	return out, nil
}

func (s *memoryStore) DeleteRelationshipsBetween(_ context.Context, userA, userB uuid.UUID) error {
	for id, f := range s.friendships {
		if (f.RequesterID == userA && f.AddresseeID == userB) ||
			(f.RequesterID == userB && f.AddresseeID == userA) {
			delete(s.friendships, id)
		}
	}
	return nil
}

func TestRequestByEmailCreatesPending(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	store.addUser("alice@example.com", alice)
	store.addUser("bob@example.com", bob)

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.RequestByEmail(context.Background(), alice, "bob@example.com"); err != nil {
		t.Fatal(err)
	}

	pending, err := store.FindPendingBetween(context.Background(), alice, bob)
	if err != nil || pending == nil {
		t.Fatal("expected pending request")
	}
}

func TestRequestByEmailRejectsSelf(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	store.addUser("alice@example.com", alice)

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	err := service.RequestByEmail(context.Background(), alice, "alice@example.com")
	if !errors.Is(err, ErrSelfRelationship) {
		t.Fatalf("expected self error, got %v", err)
	}
}

func TestRequestByEmailSilentForUnknownUser(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	store.addUser("alice@example.com", alice)

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.RequestByEmail(context.Background(), alice, "missing@example.com"); err != nil {
		t.Fatalf("expected silent success, got %v", err)
	}
	if len(store.friendships) != 0 {
		t.Fatal("expected no friendship rows")
	}
}

func TestRequestByEmailDuplicateIsSilentSuccess(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	store.addUser("alice@example.com", alice)
	store.addUser("bob@example.com", bob)

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.RequestByEmail(context.Background(), alice, "bob@example.com"); err != nil {
		t.Fatal(err)
	}
	if err := service.RequestByEmail(context.Background(), alice, "bob@example.com"); err != nil {
		t.Fatalf("expected silent success for duplicate pending, got %v", err)
	}
	if len(store.friendships) != 1 {
		t.Fatalf("expected one pending row, got %d", len(store.friendships))
	}
}

func TestAcceptAndRejectAuthorization(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	intruder := uuid.New()

	pending, err := store.CreatePending(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	service := NewServiceWithDeps(store, newMemoryLimiter(10))

	if err := service.Accept(context.Background(), intruder, pending.ID); !errors.Is(err, ErrRequestNotFound) {
		t.Fatalf("expected not-found for unauthorized accept, got %v", err)
	}

	if err := service.Accept(context.Background(), bob, pending.ID); err != nil {
		t.Fatal(err)
	}

	accepted, err := store.FindAcceptedBetween(context.Background(), alice, bob)
	if err != nil || accepted == nil {
		t.Fatal("expected accepted friendship")
	}
}

func TestRejectRequest(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	pending, err := store.CreatePending(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.Reject(context.Background(), bob, pending.ID); err != nil {
		t.Fatal(err)
	}

	f, err := store.GetByID(context.Background(), pending.ID)
	if err != nil {
		t.Fatal(err)
	}
	if f.Status != StatusRejected {
		t.Fatalf("expected rejected, got %s", f.Status)
	}
}

func TestRemoveFriend(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	pending, err := store.CreatePending(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateStatus(context.Background(), pending.ID, StatusAccepted); err != nil {
		t.Fatal(err)
	}

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.RemoveFriend(context.Background(), alice, bob); err != nil {
		t.Fatal(err)
	}
	if err := service.RemoveFriend(context.Background(), alice, bob); !errors.Is(err, ErrNotFriends) {
		t.Fatalf("expected not friends, got %v", err)
	}
}

func TestBlockRemovesRelationshipsAndPreventsRequest(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	store.addUser("alice@example.com", alice)
	store.addUser("bob@example.com", bob)

	pending, err := store.CreatePending(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateStatus(context.Background(), pending.ID, StatusAccepted); err != nil {
		t.Fatal(err)
	}

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	if err := service.BlockByUserID(context.Background(), alice, bob); err != nil {
		t.Fatal(err)
	}

	if _, ok := store.friendships[pending.ID]; ok {
		t.Fatal("expected friendship removed after block")
	}

	if err := service.RequestByEmail(context.Background(), bob, "alice@example.com"); err != nil {
		t.Fatalf("blocked target should look like silent success, got %v", err)
	}
	if len(store.friendships) != 0 {
		t.Fatal("expected no new request after block")
	}
}

func TestPrivateFriendListAccess(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	pending, err := store.CreatePending(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateStatus(context.Background(), pending.ID, StatusAccepted); err != nil {
		t.Fatal(err)
	}

	service := NewServiceWithDeps(store, newMemoryLimiter(10))
	friendsForAlice, err := service.ListFriends(context.Background(), alice)
	if err != nil {
		t.Fatal(err)
	}
	if len(friendsForAlice) != 1 || friendsForAlice[0].UserID != bob {
		t.Fatalf("unexpected alice friends: %#v", friendsForAlice)
	}

	count, err := service.FriendCount(context.Background(), bob)
	if err != nil || count != 1 {
		t.Fatalf("expected bob count 1, got %d (%v)", count, err)
	}
}

func TestConcurrentDuplicateRequests(t *testing.T) {
	store := newMemoryStore()
	alice := uuid.New()
	bob := uuid.New()
	store.addUser("alice@example.com", alice)
	store.addUser("bob@example.com", bob)

	service := NewServiceWithDeps(store, newMemoryLimiter(20))

	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- service.RequestByEmail(context.Background(), alice, "bob@example.com")
		}()
	}
	wg.Wait()
	close(errs)

	success := 0
	for err := range errs {
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		success++
	}

	if success != 20 {
		t.Fatalf("expected 20 silent successes, got %d", success)
	}
	if len(store.friendships) != 1 {
		t.Fatalf("expected one pending friendship, got %d", len(store.friendships))
	}
}
