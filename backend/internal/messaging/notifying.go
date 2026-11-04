package messaging

import (
	"context"

	"github.com/google/uuid"
)

// EnvelopeNotifier is invoked after a newly created envelope is durably stored.
type EnvelopeNotifier interface {
	NotifyEnvelope(recipientID, conversationID, envelopeID uuid.UUID)
}

// NotifyingService wraps Service to push realtime hints (Postgres remains SoT).
type NotifyingService struct {
	*Service
	notifier EnvelopeNotifier
}

func NewNotifyingService(inner *Service, notifier EnvelopeNotifier) *NotifyingService {
	return &NotifyingService{Service: inner, notifier: notifier}
}

func (s *NotifyingService) SendEnvelope(
	ctx context.Context,
	actorID, conversationID uuid.UUID,
	clientMessageID string,
	ciphertext []byte,
	contentType string,
) (SendResult, error) {
	result, err := s.Service.SendEnvelope(ctx, actorID, conversationID, clientMessageID, ciphertext, contentType)
	if err != nil {
		return result, err
	}
	if result.Created && s.notifier != nil {
		conversation, cerr := s.store.GetConversation(ctx, conversationID)
		if cerr == nil {
			if recipient, perr := peerOf(conversation, actorID); perr == nil {
				s.notifier.NotifyEnvelope(recipient, conversationID, result.Envelope.ID)
			}
		}
	}
	return result, nil
}
