package friends

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

type Status string

const (
	StatusPending  Status = "PENDING"
	StatusAccepted Status = "ACCEPTED"
	StatusRejected Status = "REJECTED"
)

var (
	ErrInvalidInput          = errors.New("invalid friends input")
	ErrSelfRelationship      = errors.New("cannot create a relationship with yourself")
	ErrUserUnavailable       = errors.New("user unavailable")
	ErrAlreadyFriends        = errors.New("users are already friends")
	ErrRequestAlreadyPending = errors.New("friend request already pending")
	ErrRequestNotFound       = errors.New("friend request not found")
	ErrNotAuthorized         = errors.New("not authorized for this relationship")
	ErrNotFriends            = errors.New("users are not friends")
	ErrBlocked               = errors.New("relationship blocked")
	ErrRateLimited           = errors.New("friend request rate limit exceeded")
)

type Friendship struct {
	ID          uuid.UUID
	RequesterID uuid.UUID
	AddresseeID uuid.UUID
	Status      Status
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type FriendSummary struct {
	UserID    uuid.UUID
	Email     string
	Since     time.Time
}

type PendingRequest struct {
	ID        uuid.UUID
	UserID    uuid.UUID
	Email     string
	CreatedAt time.Time
	Outgoing  bool
}

type BlockRecord struct {
	BlockedUserID uuid.UUID
	Email         string
	CreatedAt     time.Time
}
