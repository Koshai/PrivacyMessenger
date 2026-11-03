package friends

import (
	"context"

	"github.com/google/uuid"
)

type Store interface {
	FindActiveUserIDByEmail(ctx context.Context, emailNormalized string) (uuid.UUID, error)
	IsBlockedEitherWay(ctx context.Context, userA, userB uuid.UUID) (bool, error)
	FindAcceptedBetween(ctx context.Context, userA, userB uuid.UUID) (*Friendship, error)
	FindPendingBetween(ctx context.Context, userA, userB uuid.UUID) (*Friendship, error)
	CreatePending(ctx context.Context, requesterID, addresseeID uuid.UUID) (Friendship, error)
	GetByID(ctx context.Context, id uuid.UUID) (Friendship, error)
	UpdateStatus(ctx context.Context, id uuid.UUID, status Status) error
	DeleteByID(ctx context.Context, id uuid.UUID) error
	ListAccepted(ctx context.Context, userID uuid.UUID) ([]FriendSummary, error)
	CountAccepted(ctx context.Context, userID uuid.UUID) (int, error)
	ListIncomingPending(ctx context.Context, userID uuid.UUID) ([]PendingRequest, error)
	ListOutgoingPending(ctx context.Context, userID uuid.UUID) ([]PendingRequest, error)
	CreateBlock(ctx context.Context, blockerID, blockedID uuid.UUID) error
	DeleteBlock(ctx context.Context, blockerID, blockedID uuid.UUID) error
	ListBlocks(ctx context.Context, blockerID uuid.UUID) ([]BlockRecord, error)
	DeleteRelationshipsBetween(ctx context.Context, userA, userB uuid.UUID) error
}

type RequestLimiter interface {
	AllowRequest(ctx context.Context, requesterID uuid.UUID) error
}
