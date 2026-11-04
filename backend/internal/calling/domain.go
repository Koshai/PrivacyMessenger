package calling

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrInvalidInput       = errors.New("invalid calling input")
	ErrNotAuthorized      = errors.New("not authorized for call")
	ErrNotFriends         = errors.New("not friends")
	ErrBlocked            = errors.New("relationship blocked")
	ErrCallMissing        = errors.New("call not found")
	ErrIllegalTransition  = errors.New("illegal call state transition")
	ErrBusy               = errors.New("participant busy")
	ErrPayloadTooLarge    = errors.New("signaling payload too large")
	ErrRateLimited        = errors.New("calling rate limited")
	ErrReplay             = errors.New("replayed or forged signaling event")
	ErrCallExpired        = errors.New("call ringing expired")
)

const (
	StateRinging   = "ringing"
	StateAccepted  = "accepted"
	StateConnected = "connected"
	StateEnded     = "ended"

	MediaAudio = "audio"
	MediaVideo = "video"

	EndDeclined  = "declined"
	EndCancelled = "cancelled"
	EndHangup    = "hangup"
	EndTimeout   = "timeout"
	EndRevoked   = "revoked"
	EndBusy      = "busy"
	EndFailed    = "failed"

	MaxSDPPChars        = 64 * 1024
	MaxICECandidateLen  = 4096
	MaxICEPerCall       = 64
	DefaultRingTimeout  = 45 * time.Second
	SignalingRateLimit  = 60
	SignalingRateWindow = time.Minute
)

type Session struct {
	ID             uuid.UUID
	CallerUserID   uuid.UUID
	CalleeUserID   uuid.UUID
	CallerDeviceID uuid.UUID
	CalleeDeviceID *uuid.UUID
	MediaType      string
	State          string
	EndReason      *string
	ClientCallID   string
	SDPOffer       *string
	SDPAnswer      *string
	RingExpiresAt  time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
	AcceptedAt     *time.Time
	EndedAt        *time.Time
}

func (s Session) Active() bool {
	return s.State != StateEnded
}

func (s Session) Participant(userID uuid.UUID) bool {
	return s.CallerUserID == userID || s.CalleeUserID == userID
}

func (s Session) Peer(userID uuid.UUID) (uuid.UUID, bool) {
	switch userID {
	case s.CallerUserID:
		return s.CalleeUserID, true
	case s.CalleeUserID:
		return s.CallerUserID, true
	default:
		return uuid.Nil, false
	}
}

type ICECandidate struct {
	ID            uuid.UUID
	CallID        uuid.UUID
	SenderUserID  uuid.UUID
	Seq           int64
	Candidate     string
	SDPMID        *string
	SDPMLineIndex *int
	ClientICEID   string
	CreatedAt     time.Time
}

type InitiateResult struct {
	Session Session
	Created bool
}
