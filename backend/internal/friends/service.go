package friends

import (
	"context"
	"errors"
	"fmt"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	store   Store
	limiter RequestLimiter
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{
		store:   NewRepository(db),
		limiter: NewRateLimiter(db),
	}
}

func NewServiceWithDeps(store Store, limiter RequestLimiter) *Service {
	return &Service{store: store, limiter: limiter}
}

// RequestByEmail creates a pending friendship when the target exists.
// Unknown emails and blocked relationships return a silent success to
// reduce account enumeration.
func (s *Service) RequestByEmail(
	ctx context.Context,
	requesterID uuid.UUID,
	email string,
) error {
	if requesterID == uuid.Nil {
		return ErrInvalidInput
	}

	normalized, err := auth.NormalizeEmail(email)
	if err != nil {
		return ErrInvalidInput
	}

	if err := s.limiter.AllowRequest(ctx, requesterID); err != nil {
		return err
	}

	targetID, err := s.store.FindActiveUserIDByEmail(ctx, normalized)
	if errors.Is(err, ErrUserUnavailable) {
		return nil
	}
	if err != nil {
		return err
	}

	if targetID == requesterID {
		return ErrSelfRelationship
	}

	blocked, err := s.store.IsBlockedEitherWay(ctx, requesterID, targetID)
	if err != nil {
		return err
	}
	if blocked {
		return nil
	}

	accepted, err := s.store.FindAcceptedBetween(ctx, requesterID, targetID)
	if err != nil {
		return err
	}
	if accepted != nil {
		// Idempotent silent success — do not disclose existing relationships
		// via a distinct HTTP status from unknown emails.
		return nil
	}

	pending, err := s.store.FindPendingBetween(ctx, requesterID, targetID)
	if err != nil {
		return err
	}
	if pending != nil {
		return nil
	}

	_, err = s.store.CreatePending(ctx, requesterID, targetID)
	if err != nil {
		if errors.Is(err, ErrRequestAlreadyPending) {
			return nil
		}
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			// Concurrent duplicate insert — treat as success.
			return nil
		}
		return err
	}

	return nil
}

func (s *Service) Accept(
	ctx context.Context,
	actorID, requestID uuid.UUID,
) error {
	f, err := s.store.GetByID(ctx, requestID)
	if err != nil {
		return err
	}
	if f.Status != StatusPending || f.AddresseeID != actorID {
		// Collapse not-found and unauthorized to avoid confirming request IDs.
		return ErrRequestNotFound
	}

	blocked, err := s.store.IsBlockedEitherWay(ctx, f.RequesterID, f.AddresseeID)
	if err != nil {
		return err
	}
	if blocked {
		return ErrBlocked
	}

	return s.store.UpdateStatus(ctx, requestID, StatusAccepted)
}

func (s *Service) Reject(
	ctx context.Context,
	actorID, requestID uuid.UUID,
) error {
	f, err := s.store.GetByID(ctx, requestID)
	if err != nil {
		return err
	}
	if f.Status != StatusPending || f.AddresseeID != actorID {
		return ErrRequestNotFound
	}
	return s.store.UpdateStatus(ctx, requestID, StatusRejected)
}

func (s *Service) RemoveFriend(
	ctx context.Context,
	actorID, friendUserID uuid.UUID,
) error {
	if actorID == friendUserID {
		return ErrInvalidInput
	}

	accepted, err := s.store.FindAcceptedBetween(ctx, actorID, friendUserID)
	if err != nil {
		return err
	}
	if accepted == nil {
		return ErrNotFriends
	}

	return s.store.DeleteByID(ctx, accepted.ID)
}

func (s *Service) ListFriends(
	ctx context.Context,
	actorID uuid.UUID,
) ([]FriendSummary, error) {
	return s.store.ListAccepted(ctx, actorID)
}

func (s *Service) FriendCount(
	ctx context.Context,
	actorID uuid.UUID,
) (int, error) {
	return s.store.CountAccepted(ctx, actorID)
}

func (s *Service) ListIncoming(
	ctx context.Context,
	actorID uuid.UUID,
) ([]PendingRequest, error) {
	return s.store.ListIncomingPending(ctx, actorID)
}

func (s *Service) ListOutgoing(
	ctx context.Context,
	actorID uuid.UUID,
) ([]PendingRequest, error) {
	return s.store.ListOutgoingPending(ctx, actorID)
}

func (s *Service) BlockByUserID(
	ctx context.Context,
	actorID, targetID uuid.UUID,
) error {
	if actorID == uuid.Nil || targetID == uuid.Nil {
		return ErrInvalidInput
	}
	if actorID == targetID {
		return ErrSelfRelationship
	}

	if err := s.store.DeleteRelationshipsBetween(ctx, actorID, targetID); err != nil {
		return err
	}
	if err := s.store.CreateBlock(ctx, actorID, targetID); err != nil {
		return fmt.Errorf("block user: %w", err)
	}
	return nil
}

func (s *Service) Unblock(
	ctx context.Context,
	actorID, targetID uuid.UUID,
) error {
	if actorID == targetID {
		return ErrInvalidInput
	}
	return s.store.DeleteBlock(ctx, actorID, targetID)
}

func (s *Service) ListBlocked(
	ctx context.Context,
	actorID uuid.UUID,
) ([]BlockRecord, error) {
	return s.store.ListBlocks(ctx, actorID)
}
