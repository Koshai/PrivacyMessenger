package friends

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository struct {
	db *pgxpool.Pool
}

func NewRepository(db *pgxpool.Pool) *Repository {
	return &Repository{db: db}
}

func (r *Repository) FindActiveUserIDByEmail(
	ctx context.Context,
	emailNormalized string,
) (uuid.UUID, error) {
	var id uuid.UUID
	err := r.db.QueryRow(ctx, `
		SELECT id
		FROM users
		WHERE email_normalized = $1
		  AND deleted_at IS NULL
	`, emailNormalized).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrUserUnavailable
	}
	if err != nil {
		return uuid.Nil, fmt.Errorf("find user by email: %w", err)
	}
	return id, nil
}

func (r *Repository) IsBlockedEitherWay(
	ctx context.Context,
	userA, userB uuid.UUID,
) (bool, error) {
	var exists bool
	err := r.db.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM user_blocks
			WHERE (blocker_id = $1 AND blocked_id = $2)
			   OR (blocker_id = $2 AND blocked_id = $1)
		)
	`, userA, userB).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("check block: %w", err)
	}
	return exists, nil
}

func (r *Repository) FindAcceptedBetween(
	ctx context.Context,
	userA, userB uuid.UUID,
) (*Friendship, error) {
	var f Friendship
	err := r.db.QueryRow(ctx, `
		SELECT id, requester_id, addressee_id, status, created_at, updated_at
		FROM friendships
		WHERE status = 'ACCEPTED'
		  AND (
		        (requester_id = $1 AND addressee_id = $2)
		     OR (requester_id = $2 AND addressee_id = $1)
		  )
	`, userA, userB).Scan(
		&f.ID, &f.RequesterID, &f.AddresseeID, &f.Status, &f.CreatedAt, &f.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find accepted friendship: %w", err)
	}
	return &f, nil
}

func (r *Repository) FindPendingBetween(
	ctx context.Context,
	userA, userB uuid.UUID,
) (*Friendship, error) {
	var f Friendship
	err := r.db.QueryRow(ctx, `
		SELECT id, requester_id, addressee_id, status, created_at, updated_at
		FROM friendships
		WHERE status = 'PENDING'
		  AND (
		        (requester_id = $1 AND addressee_id = $2)
		     OR (requester_id = $2 AND addressee_id = $1)
		  )
	`, userA, userB).Scan(
		&f.ID, &f.RequesterID, &f.AddresseeID, &f.Status, &f.CreatedAt, &f.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find pending friendship: %w", err)
	}
	return &f, nil
}

func (r *Repository) CreatePending(
	ctx context.Context,
	requesterID, addresseeID uuid.UUID,
) (Friendship, error) {
	now := time.Now().UTC()
	f := Friendship{
		ID:          uuid.New(),
		RequesterID: requesterID,
		AddresseeID: addresseeID,
		Status:      StatusPending,
		CreatedAt:   now,
		UpdatedAt:   now,
	}

	_, err := r.db.Exec(ctx, `
		INSERT INTO friendships
			(id, requester_id, addressee_id, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
	`, f.ID, f.RequesterID, f.AddresseeID, f.Status, f.CreatedAt, f.UpdatedAt)
	if err != nil {
		return Friendship{}, fmt.Errorf("create pending friendship: %w", err)
	}
	return f, nil
}

func (r *Repository) GetByID(
	ctx context.Context,
	id uuid.UUID,
) (Friendship, error) {
	var f Friendship
	err := r.db.QueryRow(ctx, `
		SELECT id, requester_id, addressee_id, status, created_at, updated_at
		FROM friendships
		WHERE id = $1
	`, id).Scan(
		&f.ID, &f.RequesterID, &f.AddresseeID, &f.Status, &f.CreatedAt, &f.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Friendship{}, ErrRequestNotFound
	}
	if err != nil {
		return Friendship{}, fmt.Errorf("get friendship: %w", err)
	}
	return f, nil
}

func (r *Repository) UpdateStatus(
	ctx context.Context,
	id uuid.UUID,
	status Status,
) error {
	command, err := r.db.Exec(ctx, `
		UPDATE friendships
		SET status = $2, updated_at = NOW()
		WHERE id = $1
	`, id, status)
	if err != nil {
		return fmt.Errorf("update friendship status: %w", err)
	}
	if command.RowsAffected() == 0 {
		return ErrRequestNotFound
	}
	return nil
}

func (r *Repository) DeleteByID(
	ctx context.Context,
	id uuid.UUID,
) error {
	command, err := r.db.Exec(ctx, `
		DELETE FROM friendships WHERE id = $1
	`, id)
	if err != nil {
		return fmt.Errorf("delete friendship: %w", err)
	}
	if command.RowsAffected() == 0 {
		return ErrNotFriends
	}
	return nil
}

func (r *Repository) ListAccepted(
	ctx context.Context,
	userID uuid.UUID,
) ([]FriendSummary, error) {
	rows, err := r.db.Query(ctx, `
		SELECT
			CASE WHEN f.requester_id = $1 THEN f.addressee_id ELSE f.requester_id END AS friend_id,
			u.email,
			f.updated_at
		FROM friendships f
		JOIN users u ON u.id = CASE
			WHEN f.requester_id = $1 THEN f.addressee_id
			ELSE f.requester_id
		END
		WHERE f.status = 'ACCEPTED'
		  AND (f.requester_id = $1 OR f.addressee_id = $1)
		  AND u.deleted_at IS NULL
		ORDER BY u.email ASC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list friends: %w", err)
	}
	defer rows.Close()

	var out []FriendSummary
	for rows.Next() {
		var item FriendSummary
		if err := rows.Scan(&item.UserID, &item.Email, &item.Since); err != nil {
			return nil, fmt.Errorf("scan friend: %w", err)
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repository) CountAccepted(
	ctx context.Context,
	userID uuid.UUID,
) (int, error) {
	var count int
	err := r.db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM friendships
		WHERE status = 'ACCEPTED'
		  AND (requester_id = $1 OR addressee_id = $1)
	`, userID).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count friends: %w", err)
	}
	return count, nil
}

func (r *Repository) ListIncomingPending(
	ctx context.Context,
	userID uuid.UUID,
) ([]PendingRequest, error) {
	rows, err := r.db.Query(ctx, `
		SELECT f.id, f.requester_id, u.email, f.created_at
		FROM friendships f
		JOIN users u ON u.id = f.requester_id
		WHERE f.addressee_id = $1
		  AND f.status = 'PENDING'
		  AND u.deleted_at IS NULL
		ORDER BY f.created_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list incoming requests: %w", err)
	}
	defer rows.Close()

	var out []PendingRequest
	for rows.Next() {
		var item PendingRequest
		if err := rows.Scan(&item.ID, &item.UserID, &item.Email, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan incoming request: %w", err)
		}
		item.Outgoing = false
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repository) ListOutgoingPending(
	ctx context.Context,
	userID uuid.UUID,
) ([]PendingRequest, error) {
	rows, err := r.db.Query(ctx, `
		SELECT f.id, f.addressee_id, u.email, f.created_at
		FROM friendships f
		JOIN users u ON u.id = f.addressee_id
		WHERE f.requester_id = $1
		  AND f.status = 'PENDING'
		  AND u.deleted_at IS NULL
		ORDER BY f.created_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list outgoing requests: %w", err)
	}
	defer rows.Close()

	var out []PendingRequest
	for rows.Next() {
		var item PendingRequest
		if err := rows.Scan(&item.ID, &item.UserID, &item.Email, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan outgoing request: %w", err)
		}
		item.Outgoing = true
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repository) CreateBlock(
	ctx context.Context,
	blockerID, blockedID uuid.UUID,
) error {
	_, err := r.db.Exec(ctx, `
		INSERT INTO user_blocks (blocker_id, blocked_id)
		VALUES ($1, $2)
		ON CONFLICT DO NOTHING
	`, blockerID, blockedID)
	if err != nil {
		return fmt.Errorf("create block: %w", err)
	}
	return nil
}

func (r *Repository) DeleteBlock(
	ctx context.Context,
	blockerID, blockedID uuid.UUID,
) error {
	_, err := r.db.Exec(ctx, `
		DELETE FROM user_blocks
		WHERE blocker_id = $1 AND blocked_id = $2
	`, blockerID, blockedID)
	if err != nil {
		return fmt.Errorf("delete block: %w", err)
	}
	return nil
}

func (r *Repository) ListBlocks(
	ctx context.Context,
	blockerID uuid.UUID,
) ([]BlockRecord, error) {
	rows, err := r.db.Query(ctx, `
		SELECT b.blocked_id, u.email, b.created_at
		FROM user_blocks b
		JOIN users u ON u.id = b.blocked_id
		WHERE b.blocker_id = $1
		  AND u.deleted_at IS NULL
		ORDER BY u.email ASC
	`, blockerID)
	if err != nil {
		return nil, fmt.Errorf("list blocks: %w", err)
	}
	defer rows.Close()

	var out []BlockRecord
	for rows.Next() {
		var item BlockRecord
		if err := rows.Scan(&item.BlockedUserID, &item.Email, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan block: %w", err)
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (r *Repository) DeleteRelationshipsBetween(
	ctx context.Context,
	userA, userB uuid.UUID,
) error {
	_, err := r.db.Exec(ctx, `
		DELETE FROM friendships
		WHERE (requester_id = $1 AND addressee_id = $2)
		   OR (requester_id = $2 AND addressee_id = $1)
	`, userA, userB)
	if err != nil {
		return fmt.Errorf("delete relationships between users: %w", err)
	}
	return nil
}
