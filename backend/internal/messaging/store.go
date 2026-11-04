package messaging

import (
	"context"
	"time"

	"github.com/google/uuid"
)

type FriendshipChecker interface {
	AreAcceptedFriends(ctx context.Context, userA, userB uuid.UUID) (bool, error)
}

type PageCursor struct {
	CreatedAt time.Time
	ID        uuid.UUID
}

type Store interface {
	GetOrCreateConversation(ctx context.Context, userA, userB uuid.UUID) (Conversation, error)
	GetConversation(ctx context.Context, conversationID uuid.UUID) (Conversation, error)
	InsertEnvelope(ctx context.Context, envelope Envelope, recipientID uuid.UUID) (SendResult, error)
	ListEnvelopes(ctx context.Context, conversationID uuid.UUID, before *PageCursor, limit int) ([]Envelope, error)
	Acknowledge(ctx context.Context, recipientID, envelopeID uuid.UUID) error
	ListPendingForRecipient(ctx context.Context, recipientID uuid.UUID, limit int) ([]Envelope, error)
}
