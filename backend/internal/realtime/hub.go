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
}

type subscriber struct {
	userID uuid.UUID
	ch     chan Event
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

func (h *Hub) Subscribe(userID uuid.UUID) *subscriber {
	sub := &subscriber{
		userID: userID,
		ch:     make(chan Event, MaxQueuedEvents),
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

func (s *subscriber) Events() <-chan Event {
	return s.ch
}

func EncodeEvent(e Event) ([]byte, error) {
	return json.Marshal(e)
}
