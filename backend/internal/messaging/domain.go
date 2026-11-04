package messaging

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrInvalidInput        = errors.New("invalid messaging input")
	ErrNotAuthorized       = errors.New("not authorized for conversation")
	ErrConversationMissing = errors.New("conversation not found")
	ErrEnvelopeMissing     = errors.New("envelope not found")
	ErrNotFriends          = errors.New("participants are not friends")
	ErrMlsNotEstablished   = errors.New("mls group not established")
	ErrMlsAlreadySet       = errors.New("mls group already established")
	ErrMlsGroupMismatch    = errors.New("mls group mismatch")
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
	// ConversationSeq is allocated in the same DB transaction as the insert
	// (durable per-conversation order; not wall-clock and not a global sequence).
	ConversationSeq int64
}

type Conversation struct {
	ID               uuid.UUID
	UserA            uuid.UUID
	UserB            uuid.UUID
	CreatedAt        time.Time
	MlsGroupIDHex    *string
	MlsInitiatorID   *uuid.UUID
	MlsEstablishedAt *time.Time
}

// MLS content types (opaque to the server; routing metadata only).
const (
	ContentTypeOpaque      = "application/opaque"
	ContentTypeMLSMessage  = "application/mls-message"
	ContentTypeMLSWelcome  = "application/mls-welcome"
	ContentTypeMLSCommit   = "application/mls-commit"
	ContentTypeMLSProposal = "application/mls-proposal"
)

func IsAllowedContentType(ct string) bool {
	switch ct {
	case ContentTypeOpaque, ContentTypeMLSMessage, ContentTypeMLSWelcome,
		ContentTypeMLSCommit, ContentTypeMLSProposal, "application/octet-stream":
		return true
	default:
		return false
	}
}

func IsMLSApplication(ct string) bool {
	return ct == ContentTypeMLSMessage
}

type SendResult struct {
	Envelope Envelope
	Created  bool
}
