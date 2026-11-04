package messaging

import (
	"context"
	"time"

	"github.com/google/uuid"
)

type Service struct {
	store      Store
	friendship FriendshipChecker
}

func NewService(store Store, friendship FriendshipChecker) *Service {
	return &Service{store: store, friendship: friendship}
}

func (s *Service) OpenConversation(
	ctx context.Context,
	actorID, peerID uuid.UUID,
) (Conversation, error) {
	if actorID == uuid.Nil || peerID == uuid.Nil || actorID == peerID {
		return Conversation{}, ErrInvalidInput
	}

	ok, err := s.friendship.AreAcceptedFriends(ctx, actorID, peerID)
	if err != nil {
		return Conversation{}, err
	}
	if !ok {
		return Conversation{}, ErrNotFriends
	}

	return s.store.GetOrCreateConversation(ctx, actorID, peerID)
}

func (s *Service) SendEnvelope(
	ctx context.Context,
	actorID, conversationID uuid.UUID,
	clientMessageID string,
	ciphertext []byte,
	contentType string,
) (SendResult, error) {
	if actorID == uuid.Nil || conversationID == uuid.Nil {
		return SendResult{}, ErrInvalidInput
	}
	if clientMessageID == "" || len(clientMessageID) > 128 {
		return SendResult{}, ErrInvalidInput
	}
	if len(ciphertext) == 0 || len(ciphertext) > 64*1024 {
		return SendResult{}, ErrInvalidInput
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	if len(contentType) > 64 {
		return SendResult{}, ErrInvalidInput
	}

	conversation, err := s.store.GetConversation(ctx, conversationID)
	if err != nil {
		return SendResult{}, err
	}

	recipientID, err := peerOf(conversation, actorID)
	if err != nil {
		return SendResult{}, err
	}

	ok, err := s.friendship.AreAcceptedFriends(ctx, actorID, recipientID)
	if err != nil {
		return SendResult{}, err
	}
	if !ok {
		return SendResult{}, ErrNotFriends
	}

	envelope := Envelope{
		ID:              uuid.New(),
		ConversationID:  conversationID,
		SenderID:        actorID,
		ClientMessageID: clientMessageID,
		Ciphertext:      append([]byte(nil), ciphertext...),
		ContentType:     contentType,
		CreatedAt:       time.Now().UTC(),
	}

	return s.store.InsertEnvelope(ctx, envelope, recipientID)
}

func (s *Service) ListHistory(
	ctx context.Context,
	actorID, conversationID uuid.UUID,
	before *PageCursor,
	limit int,
) ([]Envelope, error) {
	conversation, err := s.store.GetConversation(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	if _, err := peerOf(conversation, actorID); err != nil {
		return nil, err
	}
	return s.store.ListEnvelopes(ctx, conversationID, before, limit)
}

func (s *Service) Acknowledge(
	ctx context.Context,
	actorID, envelopeID uuid.UUID,
) error {
	if actorID == uuid.Nil || envelopeID == uuid.Nil {
		return ErrInvalidInput
	}
	return s.store.Acknowledge(ctx, actorID, envelopeID)
}

func (s *Service) SyncPending(
	ctx context.Context,
	actorID uuid.UUID,
	limit int,
) ([]Envelope, error) {
	if actorID == uuid.Nil {
		return nil, ErrInvalidInput
	}
	return s.store.ListPendingForRecipient(ctx, actorID, limit)
}

func peerOf(c Conversation, actorID uuid.UUID) (uuid.UUID, error) {
	switch actorID {
	case c.UserA:
		return c.UserB, nil
	case c.UserB:
		return c.UserA, nil
	default:
		return uuid.Nil, ErrNotAuthorized
	}
}
