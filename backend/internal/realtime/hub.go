package realtime

import (
	"encoding/json"
	"sync"

	"github.com/google/uuid"
)

const MaxQueuedEvents = 64

type Event struct {
	Type           string `json:"type"`
	EnvelopeID     string `json:"envelope_id,omitempty"`
	ConversationID string `json:"conversation_id,omitempty"`
	Cursor         string `json:"cursor,omitempty"`
	Reason         string `json:"reason,omitempty"`
}

type CloseFunc func(reason string)

type subscriber struct {
	userID    uuid.UUID
	deviceID  uuid.UUID
	tokenHash string
	ch        chan Event
	closeFn   CloseFunc
}

// Hub fans out envelope notifications in-process. PostgreSQL remains SoT;
// clients always resume via pending sync after reconnect.
type Hub struct {
	mu   sync.Mutex
	subs map[uuid.UUID]map[*subscriber]struct{}
}

func NewHub() *Hub {
	return &Hub{subs: map[uuid.UUID]map[*subscriber]struct{}{}}
}

func (h *Hub) Subscribe(userID, deviceID uuid.UUID, tokenHash string, closeFn CloseFunc) *subscriber {
	sub := &subscriber{
		userID:    userID,
		deviceID:  deviceID,
		tokenHash: tokenHash,
		ch:        make(chan Event, MaxQueuedEvents),
		closeFn:   closeFn,
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[userID] == nil {
		h.subs[userID] = map[*subscriber]struct{}{}
	}
	h.subs[userID][sub] = struct{}{}
	return sub
}

func (h *Hub) Unsubscribe(sub *subscriber) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set, ok := h.subs[sub.userID]; ok {
		delete(set, sub)
		if len(set) == 0 {
			delete(h.subs, sub.userID)
		}
	}
	close(sub.ch)
}

func (h *Hub) NotifyUser(userID uuid.UUID, event Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for sub := range h.subs[userID] {
		select {
		case sub.ch <- event:
		default:
			// Drop when queue is full; client must sync pending from Postgres.
		}
	}
}

// DisconnectToken closes all connections authenticated with the given token hash.
func (h *Hub) DisconnectToken(tokenHash string, reason string) int {
	h.mu.Lock()
	targets := make([]*subscriber, 0)
	for _, set := range h.subs {
		for sub := range set {
			if sub.tokenHash == tokenHash {
				targets = append(targets, sub)
			}
		}
	}
	h.mu.Unlock()

	for _, sub := range targets {
		if sub.closeFn != nil {
			sub.closeFn(reason)
		}
	}
	return len(targets)
}

// DisconnectUser closes all connections for a user (e.g. device replacement).
func (h *Hub) DisconnectUser(userID uuid.UUID, reason string) int {
	h.mu.Lock()
	targets := make([]*subscriber, 0)
	for sub := range h.subs[userID] {
		targets = append(targets, sub)
	}
	h.mu.Unlock()
	for _, sub := range targets {
		if sub.closeFn != nil {
			sub.closeFn(reason)
		}
	}
	return len(targets)
}

func (s *subscriber) Events() <-chan Event {
	return s.ch
}

func (s *subscriber) TokenHash() string { return s.tokenHash }

func EncodeEvent(e Event) ([]byte, error) {
	return json.Marshal(e)
}
