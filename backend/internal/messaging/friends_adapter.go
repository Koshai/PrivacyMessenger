package messaging

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresFriendshipChecker reads accepted friendships without depending on
// friends service internals beyond the shared database schema.
type PostgresFriendshipChecker struct {
	db *pgxpool.Pool
}

func NewPostgresFriendshipChecker(db *pgxpool.Pool) *PostgresFriendshipChecker {
	return &PostgresFriendshipChecker{db: db}
}

func (c *PostgresFriendshipChecker) AreAcceptedFriends(
	ctx context.Context,
	userA, userB uuid.UUID,
) (bool, error) {
	var exists bool
	err := c.db.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM friendships
			WHERE status = 'ACCEPTED'
			  AND (
			        (requester_id = $1 AND addressee_id = $2)
			     OR (requester_id = $2 AND addressee_id = $1)
			  )
		)
	`, userA, userB).Scan(&exists)
	return exists, err
}
