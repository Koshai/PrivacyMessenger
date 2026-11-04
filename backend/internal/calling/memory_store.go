package calling

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
)

type memoryStore struct {
	mu       sync.Mutex
	sessions map[uuid.UUID]Session
	byClient map[string]uuid.UUID // caller|clientCallID
	ice      map[uuid.UUID][]ICECandidate
	iceSeq   map[uuid.UUID]int64
}

func NewMemoryStore() Store {
	return &memoryStore{
		sessions: map[uuid.UUID]Session{},
		byClient: map[string]uuid.UUID{},
		ice:      map[uuid.UUID][]ICECandidate{},
		iceSeq:   map[uuid.UUID]int64{},
	}
}

func clientKey(caller uuid.UUID, clientCallID string) string {
	return caller.String() + "|" + clientCallID
}

func (m *memoryStore) CreateSession(_ context.Context, session Session) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := clientKey(session.CallerUserID, session.ClientCallID)
	if id, ok := m.byClient[key]; ok {
		return m.sessions[id], nil
	}
	m.sessions[session.ID] = session
	m.byClient[key] = session.ID
	return session, nil
}

func (m *memoryStore) GetByID(_ context.Context, callID uuid.UUID) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[callID]
	if !ok {
		return Session{}, ErrCallMissing
	}
	return cloneSession(s), nil
}

func (m *memoryStore) GetByCallerClientID(_ context.Context, callerUserID uuid.UUID, clientCallID string) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.byClient[clientKey(callerUserID, clientCallID)]
	if !ok {
		return Session{}, ErrCallMissing
	}
	return cloneSession(m.sessions[id]), nil
}

func (m *memoryStore) FindActiveForUser(_ context.Context, userID uuid.UUID) (Session, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if s.State == StateEnded {
			continue
		}
		if s.CallerUserID == userID || s.CalleeUserID == userID {
			return cloneSession(s), true, nil
		}
	}
	return Session{}, false, nil
}

func (m *memoryStore) UpdateSession(_ context.Context, session Session) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[session.ID]; !ok {
		return Session{}, ErrCallMissing
	}
	m.sessions[session.ID] = session
	return cloneSession(session), nil
}

func (m *memoryStore) ClearSignaling(_ context.Context, callID uuid.UUID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[callID]
	if !ok {
		return ErrCallMissing
	}
	s.SDPOffer = nil
	s.SDPAnswer = nil
	m.sessions[callID] = s
	return nil
}

func (m *memoryStore) InsertICE(_ context.Context, ice ICECandidate) (ICECandidate, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[ice.CallID]; !ok {
		return ICECandidate{}, false, ErrCallMissing
	}
	for _, existing := range m.ice[ice.CallID] {
		if existing.SenderUserID == ice.SenderUserID && existing.ClientICEID == ice.ClientICEID {
			return existing, false, nil
		}
	}
	m.iceSeq[ice.CallID]++
	ice.Seq = m.iceSeq[ice.CallID]
	m.ice[ice.CallID] = append(m.ice[ice.CallID], ice)
	return ice, true, nil
}

func (m *memoryStore) ListICEAfter(_ context.Context, callID uuid.UUID, afterSeq int64, limit int) ([]ICECandidate, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]ICECandidate, 0)
	for _, ice := range m.ice[callID] {
		if ice.Seq <= afterSeq {
			continue
		}
		out = append(out, ice)
		if len(out) >= limit {
			break
		}
	}
	return out, nil
}

func (m *memoryStore) DeleteICEForCall(_ context.Context, callID uuid.UUID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.ice, callID)
	delete(m.iceSeq, callID)
	return nil
}

func (m *memoryStore) ListExpiredRinging(_ context.Context, now time.Time, limit int) ([]Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Session, 0)
	for _, s := range m.sessions {
		if s.State == StateRinging && !now.Before(s.RingExpiresAt) {
			out = append(out, cloneSession(s))
			if len(out) >= limit {
				break
			}
		}
	}
	return out, nil
}

func (m *memoryStore) CountICE(_ context.Context, callID uuid.UUID) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.ice[callID]), nil
}

func cloneSession(s Session) Session {
	out := s
	if s.CalleeDeviceID != nil {
		id := *s.CalleeDeviceID
		out.CalleeDeviceID = &id
	}
	if s.EndReason != nil {
		r := *s.EndReason
		out.EndReason = &r
	}
	if s.SDPOffer != nil {
		o := *s.SDPOffer
		out.SDPOffer = &o
	}
	if s.SDPAnswer != nil {
		a := *s.SDPAnswer
		out.SDPAnswer = &a
	}
	if s.AcceptedAt != nil {
		t := *s.AcceptedAt
		out.AcceptedAt = &t
	}
	if s.EndedAt != nil {
		t := *s.EndedAt
		out.EndedAt = &t
	}
	return out
}
