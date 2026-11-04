package messaging

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

type memoryFriends struct {
	pairs map[[2]uuid.UUID]bool
}

func (m *memoryFriends) AreAcceptedFriends(_ context.Context, a, b uuid.UUID) (bool, error) {
	return m.pairs[[2]uuid.UUID{a, b}] || m.pairs[[2]uuid.UUID{b, a}], nil
}

type memoryStore struct {
	mu            sync.Mutex
	conversations map[uuid.UUID]Conversation
	byPair        map[[2]uuid.UUID]uuid.UUID
	envelopes     map[uuid.UUID]Envelope
	byClient      map[string]uuid.UUID
	deliveries    map[[2]uuid.UUID]*time.Time // envelope+recipient -> ack
}

func newMemoryStore() *memoryStore {
	return &memoryStore{
		conversations: map[uuid.UUID]Conversation{},
		byPair:        map[[2]uuid.UUID]uuid.UUID{},
		envelopes:     map[uuid.UUID]Envelope{},
		byClient:      map[string]uuid.UUID{},
		deliveries:    map[[2]uuid.UUID]*time.Time{},
	}
}

func (m *memoryStore) GetOrCreateConversation(_ context.Context, userA, userB uuid.UUID) (Conversation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	low, high := userA, userB
	if low.String() > high.String() {
		low, high = high, low
	}
	key := [2]uuid.UUID{low, high}
	if id, ok := m.byPair[key]; ok {
		return m.conversations[id], nil
	}
	c := Conversation{ID: uuid.New(), UserA: low, UserB: high, CreatedAt: time.Now().UTC()}
	m.conversations[c.ID] = c
	m.byPair[key] = c.ID
	return c, nil
}

func (m *memoryStore) GetConversation(_ context.Context, conversationID uuid.UUID) (Conversation, error) {
	c, ok := m.conversations[conversationID]
	if !ok {
		return Conversation{}, ErrConversationMissing
	}
	return c, nil
}

func (m *memoryStore) InsertEnvelope(_ context.Context, envelope Envelope, recipientID uuid.UUID) (SendResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := envelope.ConversationID.String() + "|" + envelope.SenderID.String() + "|" + envelope.ClientMessageID
	if id, ok := m.byClient[key]; ok {
		return SendResult{Envelope: m.envelopes[id], Created: false}, nil
	}
	m.envelopes[envelope.ID] = envelope
	m.byClient[key] = envelope.ID
	m.deliveries[[2]uuid.UUID{envelope.ID, recipientID}] = nil
	return SendResult{Envelope: envelope, Created: true}, nil
}

func (m *memoryStore) ListEnvelopes(_ context.Context, conversationID uuid.UUID, _ *PageCursor, limit int) ([]Envelope, error) {
	var out []Envelope
	for _, e := range m.envelopes {
		if e.ConversationID == conversationID {
			out = append(out, e)
		}
	}
	if len(out) > limit && limit > 0 {
		out = out[:limit]
	}
	return out, nil
}

func (m *memoryStore) Acknowledge(_ context.Context, recipientID, envelopeID uuid.UUID) error {
	key := [2]uuid.UUID{envelopeID, recipientID}
	if _, ok := m.deliveries[key]; !ok {
		return ErrEnvelopeMissing
	}
	now := time.Now().UTC()
	m.deliveries[key] = &now
	return nil
}

func (m *memoryStore) ListPendingForRecipient(_ context.Context, recipientID uuid.UUID, _ int) ([]Envelope, error) {
	var out []Envelope
	for key, ack := range m.deliveries {
		if key[1] == recipientID && ack == nil {
			out = append(out, m.envelopes[key[0]])
		}
	}
	return out, nil
}

func TestSendEnvelopeRequiresFriendship(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	service := NewService(store, &memoryFriends{pairs: map[[2]uuid.UUID]bool{}})

	_, err := service.OpenConversation(context.Background(), alice, bob)
	if err != ErrNotFriends {
		t.Fatalf("expected not friends, got %v", err)
	}
}

func TestSendEnvelopeIdempotentByClientMessageID(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)

	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	first, err := service.SendEnvelope(
		context.Background(), alice, conversation.ID, "msg-1", []byte{0x01, 0x02}, "application/opaque",
	)
	if err != nil || !first.Created {
		t.Fatalf("first send failed: %#v %v", first, err)
	}

	second, err := service.SendEnvelope(
		context.Background(), alice, conversation.ID, "msg-1", []byte{0x01, 0x02}, "application/opaque",
	)
	if err != nil || second.Created {
		t.Fatalf("expected idempotent hit, got %#v %v", second, err)
	}
	if first.Envelope.ID != second.Envelope.ID {
		t.Fatal("idempotent send must return same envelope id")
	}
}

func TestUnauthorizedHistoryAccess(t *testing.T) {
	alice, bob, eve := uuid.New(), uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)

	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	_, err = service.ListHistory(context.Background(), eve, conversation.ID, nil, 10)
	if err != ErrNotAuthorized {
		t.Fatalf("expected unauthorized, got %v", err)
	}
}

func TestAcknowledgeAndPendingSync(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)

	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	sent, err := service.SendEnvelope(
		context.Background(), alice, conversation.ID, "msg-2", []byte{0xAA}, "application/opaque",
	)
	if err != nil {
		t.Fatal(err)
	}

	pending, err := service.SyncPending(context.Background(), bob, 10)
	if err != nil || len(pending) != 1 {
		t.Fatalf("expected one pending, got %#v %v", pending, err)
	}

	if err := service.Acknowledge(context.Background(), bob, sent.Envelope.ID); err != nil {
		t.Fatal(err)
	}

	pending, err = service.SyncPending(context.Background(), bob, 10)
	if err != nil || len(pending) != 0 {
		t.Fatalf("expected no pending after ack, got %#v %v", pending, err)
	}
}

func TestRejectsEmptyCiphertext(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)
	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.SendEnvelope(context.Background(), alice, conversation.ID, "msg", nil, "application/opaque")
	if err != ErrInvalidInput {
		t.Fatalf("expected invalid input, got %v", err)
	}
}
