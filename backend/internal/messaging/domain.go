package messaging

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrInvalidInput       = errors.New("invalid messaging input")
	ErrNotAuthorized      = errors.New("not authorized for conversation")
	ErrConversationMissing = errors.New("conversation not found")
	ErrEnvelopeMissing    = errors.New("envelope not found")
	ErrNotFriends         = errors.New("participants are not friends")
)

// Envelope is opaque ciphertext only. The backend must never interpret payload bytes.
type Envelope struct {
	ID              uuid.UUID
	ConversationID  uuid.UUID
	SenderID        uuid.UUID
	ClientMessageID string
	Ciphertext      []byte
	ContentType     string
	CreatedAt       time.Time
}

type Conversation struct {
	ID        uuid.UUID
	UserA     uuid.UUID
	UserB     uuid.UUID
	CreatedAt time.Time
}

type SendResult struct {
	Envelope Envelope
	Created  bool
}
