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
	CreateSession(ctx context.Context, session Session) (Session, error)
	GetByID(ctx context.Context, callID uuid.UUID) (Session, error)
	GetByCallerClientID(ctx context.Context, callerUserID uuid.UUID, clientCallID string) (Session, error)
	FindActiveForUser(ctx context.Context, userID uuid.UUID) (Session, bool, error)
	UpdateSession(ctx context.Context, session Session) (Session, error)
	ClearSignaling(ctx context.Context, callID uuid.UUID) error
	InsertICE(ctx context.Context, ice ICECandidate) (ICECandidate, bool, error)
	ListICEAfter(ctx context.Context, callID uuid.UUID, afterSeq int64, limit int) ([]ICECandidate, error)
	DeleteICEForCall(ctx context.Context, callID uuid.UUID) error
	ListExpiredRinging(ctx context.Context, now time.Time, limit int) ([]Session, error)
	CountICE(ctx context.Context, callID uuid.UUID) (int, error)
}
