package crypto

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// Simple in-process rate limiter for crypto endpoints (per user).
type RateLimiter struct {
	mu       sync.Mutex
	windows  map[uuid.UUID][]time.Time
	limit    int
	interval time.Duration
	now      func() time.Time
}

func NewRateLimiter(limit int, interval time.Duration) *RateLimiter {
	return &RateLimiter{
		windows:  map[uuid.UUID][]time.Time{},
		limit:    limit,
		interval: interval,
		now:      time.Now,
	}
}

func (r *RateLimiter) Allow(userID uuid.UUID) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now().UTC()
	cutoff := now.Add(-r.interval)
	events := r.windows[userID]
	kept := events[:0]
	for _, t := range events {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= r.limit {
		r.windows[userID] = kept
		return false
	}
	kept = append(kept, now)
	r.windows[userID] = kept
	return true
}
