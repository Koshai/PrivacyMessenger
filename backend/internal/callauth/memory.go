package callauth

import (
	"context"
	"sync"

	"github.com/google/uuid"
)

type MemoryStore struct {
	mu     sync.Mutex
	keys   map[uuid.UUID][]byte
	frames map[uuid.UUID][]Frame
	byID   map[string]Frame
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		keys:   map[uuid.UUID][]byte{},
		frames: map[uuid.UUID][]Frame{},
		byID:   map[string]Frame{},
	}
}

func (m *MemoryStore) RegisterKey(_ context.Context, userID, deviceID uuid.UUID, publicKey []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing, ok := m.keys[deviceID]; ok {
		if !bytesEqual(existing, publicKey) {
			return ErrReplay
		}
		return nil
	}
	m.keys[deviceID] = append([]byte(nil), publicKey...)
	_ = userID
	return nil
}

func (m *MemoryStore) KeyFor(_ context.Context, _, deviceID uuid.UUID) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key, ok := m.keys[deviceID]
	if !ok {
		return nil, ErrInvalid
	}
	return append([]byte(nil), key...), nil
}

func (m *MemoryStore) PutFrame(_ context.Context, frame Frame) (Frame, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if prev, ok := m.byID[frame.ClientAuthID]; ok {
		if prev.CallID != frame.CallID || prev.Kind != frame.Kind || !sameFrame(prev, frame) {
			return Frame{}, false, ErrReplay
		}
		return prev, false, nil
	}
	list := m.frames[frame.CallID]
	for _, existing := range list {
		if existing.SenderDevice == frame.SenderDevice && existing.Kind == frame.Kind {
			if sameFrame(existing, frame) {
				return existing, false, nil
			}
			return Frame{}, false, ErrReplay
		}
	}
	m.frames[frame.CallID] = append(list, frame)
	m.byID[frame.ClientAuthID] = frame
	return frame, true, nil
}

func (m *MemoryStore) Frames(_ context.Context, callID uuid.UUID) ([]Frame, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	src := m.frames[callID]
	out := make([]Frame, len(src))
	copy(out, src)
	return out, nil
}

func (m *MemoryStore) Purge(_ context.Context, callID uuid.UUID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, f := range m.frames[callID] {
		delete(m.byID, f.ClientAuthID)
	}
	delete(m.frames, callID)
	return nil
}

func sameFrame(a, b Frame) bool {
	return a.Kind == b.Kind && bytesEqual(a.Nonce, b.Nonce) && bytesEqual(a.CallKey, b.CallKey) &&
		bytesEqual(a.MLS, b.MLS) && bytesEqual(a.DTLSLocal, b.DTLSLocal) && bytesEqual(a.DTLSRemote, b.DTLSRemote) &&
		bytesEqual(a.Signature, b.Signature) && a.SenderDevice == b.SenderDevice
}
