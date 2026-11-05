package calling

import (
	"context"
	"time"

	"github.com/google/uuid"
)

type FriendshipChecker interface {
	AreAcceptedFriends(ctx context.Context, a, b uuid.UUID) (bool, error)
}

type BlockChecker interface {
	IsBlockedEitherWay(ctx context.Context, a, b uuid.UUID) (bool, error)
}

type Store interface {
	GetByID(ctx context.Context, callID uuid.UUID) (Session, error)
	GetByCallerClientID(ctx context.Context, callerUserID uuid.UUID, clientCallID string) (Session, error)
	FindActiveForUser(ctx context.Context, userID uuid.UUID) (Session, bool, error)

	// CreateSessionExclusive creates a ringing call only if neither user is busy.
	// Uses transactional locking; returns ErrBusy on conflict.
	CreateSessionExclusive(ctx context.Context, session Session) (Session, error)

	// UpdateSessionIfVersion applies updates when version matches; bumps version.
	UpdateSessionIfVersion(ctx context.Context, expectedVersion int64, session Session) (Session, error)

	// EndSessionAtomic marks ended, clears SDP, deletes ICE in one transaction.
	EndSessionAtomic(ctx context.Context, expectedVersion int64, session Session) (Session, error)

	// InsertICEExclusive inserts with row lock + limit enforcement; idempotent on client_ice_id.
	InsertICEExclusive(ctx context.Context, ice ICECandidate) (ICECandidate, bool, error)

	ListICEAfter(ctx context.Context, callID uuid.UUID, afterSeq int64, limit int) ([]ICECandidate, error)
	ListExpiredRinging(ctx context.Context, now time.Time, limit int) ([]Session, error)
}
