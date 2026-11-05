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
	byClient map[string]uuid.UUID
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

func (m *memoryStore) CreateSessionExclusive(_ context.Context, session Session) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := clientKey(session.CallerUserID, session.ClientCallID)
	if id, ok := m.byClient[key]; ok {
		return cloneSession(m.sessions[id]), nil
	}
	for _, s := range m.sessions {
		if s.State == StateEnded {
			continue
		}
		if s.CallerUserID == session.CallerUserID || s.CalleeUserID == session.CallerUserID ||
			s.CallerUserID == session.CalleeUserID || s.CalleeUserID == session.CalleeUserID {
			return Session{}, ErrBusy
		}
	}
	session.Version = 0
	m.sessions[session.ID] = session
	m.byClient[key] = session.ID
	return cloneSession(session), nil
}

func (m *memoryStore) UpdateSessionIfVersion(_ context.Context, expectedVersion int64, session Session) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.sessions[session.ID]
	if !ok {
		return Session{}, ErrCallMissing
	}
	if cur.Version != expectedVersion {
		return Session{}, ErrStaleUpdate
	}
	session.Version = expectedVersion + 1
	m.sessions[session.ID] = session
	return cloneSession(session), nil
}

func (m *memoryStore) EndSessionAtomic(_ context.Context, expectedVersion int64, session Session) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.sessions[session.ID]
	if !ok {
		return Session{}, ErrCallMissing
	}
	if cur.Version != expectedVersion {
		return Session{}, ErrStaleUpdate
	}
	session.Version = expectedVersion + 1
	session.SDPOffer = nil
	session.SDPAnswer = nil
	m.sessions[session.ID] = session
	delete(m.ice, session.ID)
	delete(m.iceSeq, session.ID)
	return cloneSession(session), nil
}

func (m *memoryStore) InsertICEExclusive(_ context.Context, ice ICECandidate) (ICECandidate, bool, error) {
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
	if len(m.ice[ice.CallID]) >= MaxICEPerCall {
		return ICECandidate{}, false, ErrPayloadTooLarge
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
