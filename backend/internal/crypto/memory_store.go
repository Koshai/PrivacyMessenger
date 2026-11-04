package crypto

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
)

type MemoryStore struct {
	mu       sync.Mutex
	idents   map[uuid.UUID]DeviceIdentity
	packages map[uuid.UUID]KeyPackage
	now      func() time.Time
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		idents:   map[uuid.UUID]DeviceIdentity{},
		packages: map[uuid.UUID]KeyPackage{},
		now:      func() time.Time { return time.Now().UTC() },
	}
}

func (m *MemoryStore) UpsertIdentity(_ context.Context, identity DeviceIdentity) (DeviceIdentity, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	existing, ok := m.idents[identity.DeviceID]
	if ok {
		if existing.RevokedAt != nil {
			return DeviceIdentity{}, false, ErrIdentityRevoked
		}
		if !bytesEqual(existing.PublicIdentityKey, identity.PublicIdentityKey) {
			return DeviceIdentity{}, false, ErrIdentityMismatch
		}
		existing.UpdatedAt = identity.UpdatedAt
		m.idents[identity.DeviceID] = existing
		return existing, false, nil
	}
	m.idents[identity.DeviceID] = identity
	return identity, true, nil
}

func (m *MemoryStore) GetIdentity(_ context.Context, deviceID uuid.UUID) (DeviceIdentity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.idents[deviceID]
	if !ok {
		return DeviceIdentity{}, ErrIdentityMissing
	}
	return id, nil
}

func (m *MemoryStore) GetActiveIdentitiesForUser(_ context.Context, userID uuid.UUID) ([]DeviceIdentity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]DeviceIdentity, 0)
	for _, id := range m.idents {
		if id.UserID == userID && id.RevokedAt == nil {
			out = append(out, id)
		}
	}
	return out, nil
}

func (m *MemoryStore) RevokeIdentity(_ context.Context, userID, deviceID uuid.UUID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.idents[deviceID]
	if !ok || id.UserID != userID {
		return ErrIdentityMissing
	}
	now := m.now()
	id.RevokedAt = &now
	m.idents[deviceID] = id
	return nil
}

func (m *MemoryStore) InsertKeyPackages(_ context.Context, packages []KeyPackage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range packages {
		m.packages[p.ID] = p
	}
	return nil
}

func (m *MemoryStore) CountAvailablePackages(_ context.Context, deviceID uuid.UUID) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	n := 0
	for _, p := range m.packages {
		if p.DeviceID == deviceID && p.ConsumedAt == nil && p.ReservedAt == nil && p.ExpiresAt.After(now) {
			n++
		}
	}
	return n, nil
}

func (m *MemoryStore) ReserveOne(_ context.Context, ownerUserID, requesterUserID uuid.UUID) (KeyPackage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	for id, p := range m.packages {
		if p.UserID != ownerUserID {
			continue
		}
		if p.ConsumedAt != nil || p.ReservedAt != nil || !p.ExpiresAt.After(now) {
			continue
		}
		p.ReservedAt = &now
		p.ReservedByUserID = &requesterUserID
		m.packages[id] = p
		return p, nil
	}
	return KeyPackage{}, ErrNoKeyPackage
}

func (m *MemoryStore) ConsumeReserved(_ context.Context, packageID, requesterUserID uuid.UUID) (KeyPackage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.packages[packageID]
	if !ok || p.ReservedByUserID == nil || *p.ReservedByUserID != requesterUserID {
		return KeyPackage{}, ErrPackageUnavailable
	}
	if p.ConsumedAt != nil {
		return KeyPackage{}, ErrPackageUnavailable
	}
	now := m.now()
	p.ConsumedAt = &now
	m.packages[packageID] = p
	return p, nil
}

func (m *MemoryStore) ReleaseExpiredReservations(_ context.Context, olderThan time.Duration) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cutoff := m.now().Add(-olderThan)
	var n int64
	for id, p := range m.packages {
		if p.ReservedAt != nil && p.ConsumedAt == nil && p.ReservedAt.Before(cutoff) {
			p.ReservedAt = nil
			p.ReservedByUserID = nil
			m.packages[id] = p
			n++
		}
	}
	return n, nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
