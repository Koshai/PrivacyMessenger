package friends

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	FriendRequestWindow = 15 * time.Minute
	MaxFriendRequests   = 10
)

type RateLimiter struct {
	db *pgxpool.Pool
}

func NewRateLimiter(db *pgxpool.Pool) *RateLimiter {
	return &RateLimiter{db: db}
}

func (r *RateLimiter) AllowRequest(
	ctx context.Context,
	requesterID uuid.UUID,
) error {
	var allowed bool

	err := r.db.QueryRow(ctx, `
		WITH attempt AS (
			INSERT INTO friend_request_limits
				(requester_id, window_started_at, request_count)
			VALUES ($1, NOW(), 1)
			ON CONFLICT (requester_id)
			DO UPDATE SET
				window_started_at = CASE
					WHEN friend_request_limits.window_started_at
					     <= NOW() - INTERVAL '15 minutes'
					THEN NOW()
					ELSE friend_request_limits.window_started_at
				END,
				request_count = CASE
					WHEN friend_request_limits.window_started_at
					     <= NOW() - INTERVAL '15 minutes'
					THEN 1
					ELSE friend_request_limits.request_count + 1
				END
			RETURNING request_count
		)
		SELECT request_count <= $2 FROM attempt
	`, requesterID, MaxFriendRequests).Scan(&allowed)
	if err != nil {
		return fmt.Errorf("check friend request limit: %w", err)
	}

	if !allowed {
		return ErrRateLimited
	}

	return nil
}
