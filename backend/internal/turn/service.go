package turn

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// Service issues credentials with in-process rate limiting.
type Service struct {
	cfg   Config
	limit int
	now   func() time.Time

	mu      sync.Mutex
	windows map[uuid.UUID][]time.Time
}

func NewService(cfg Config, perMinute int) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if perMinute <= 0 {
		perMinute = 30
	}
	return &Service{
		cfg:     cfg,
		limit:   perMinute,
		now:     time.Now,
		windows: map[uuid.UUID][]time.Time{},
	}, nil
}

func (s *Service) SetNowForTest(now func() time.Time) {
	s.now = now
}

func (s *Service) Issue(userID uuid.UUID) (Credentials, error) {
	if !s.allow(userID) {
		return Credentials{}, ErrRateLimited
	}
	return Issue(s.cfg, userID, s.now())
}

func (s *Service) allow(userID uuid.UUID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().UTC()
	cutoff := now.Add(-time.Minute)
	kept := s.windows[userID][:0]
	for _, t := range s.windows[userID] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= s.limit {
		s.windows[userID] = kept
		return false
	}
	s.windows[userID] = append(kept, now)
	return true
}
