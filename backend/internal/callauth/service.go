package callauth

import (
	"context"
	"time"

	"github.com/google/uuid"
)

const AuthWindow = 90 * time.Second

// Frame is a relayed hello or confirm. Private keys are never present.
type Frame struct {
	CallID       uuid.UUID
	SenderUser   uuid.UUID
	SenderDevice uuid.UUID
	Kind         string
	ClientAuthID string
	Nonce        []byte
	CallKey      []byte
	MLS          []byte
	DTLSLocal    []byte
	DTLSRemote   []byte
	Signature    []byte
	CreatedAt    time.Time
}

type CallView struct {
	ID           uuid.UUID
	CallerUser   uuid.UUID
	CalleeUser   uuid.UUID
	CallerDevice uuid.UUID
	CalleeDevice *uuid.UUID
	MediaAudio   bool
	Ended        bool
	AcceptedAt   *time.Time
	CreatedAt    time.Time
}

type CallLookup interface {
	CallFor(ctx context.Context, actor uuid.UUID, callID uuid.UUID) (CallView, error)
}

type Revocation interface {
	DeviceRevoked(ctx context.Context, userID, deviceID uuid.UUID) (bool, error)
}

type Store interface {
	RegisterKey(ctx context.Context, userID, deviceID uuid.UUID, publicKey []byte) error
	KeyFor(ctx context.Context, userID, deviceID uuid.UUID) ([]byte, error)
	PutFrame(ctx context.Context, frame Frame) (Frame, bool, error)
	Frames(ctx context.Context, callID uuid.UUID) ([]Frame, error)
	Purge(ctx context.Context, callID uuid.UUID) error
}

type Service struct {
	store  Store
	calls  CallLookup
	revoke Revocation
	now    func() time.Time
}

func NewService(store Store, calls CallLookup, revoke Revocation) *Service {
	return &Service{store: store, calls: calls, revoke: revoke, now: time.Now}
}

func (s *Service) RegisterKey(ctx context.Context, userID, deviceID uuid.UUID, publicKey []byte) error {
	if userID == uuid.Nil || deviceID == uuid.Nil || len(publicKey) != KeySize {
		return ErrInvalid
	}
	revoked, err := s.revoke.DeviceRevoked(ctx, userID, deviceID)
	if err != nil {
		return err
	}
	if revoked {
		return ErrRevoked
	}
	return s.store.RegisterKey(ctx, userID, deviceID, append([]byte(nil), publicKey...))
}

type SubmitInput struct {
	CallID       uuid.UUID
	ActorUser    uuid.UUID
	ActorDevice  uuid.UUID
	Kind         string
	ClientAuthID string
	Nonce        []byte
	CallKey      []byte
	MLS          []byte
	DTLSLocal    []byte
	DTLSRemote   []byte
	Signature    []byte
}

func (s *Service) Submit(ctx context.Context, in SubmitInput) (Frame, error) {
	if in.Kind != KindHello && in.Kind != KindConfirm {
		return Frame{}, ErrInvalid
	}
	if in.ClientAuthID == "" || len(in.ClientAuthID) > 80 {
		return Frame{}, ErrInvalid
	}
	call, err := s.calls.CallFor(ctx, in.ActorUser, in.CallID)
	if err != nil {
		return Frame{}, err
	}
	if call.Ended {
		_ = s.store.Purge(ctx, call.ID)
		return Frame{}, ErrInvalid
	}
	if call.CallerUser != in.ActorUser && call.CalleeUser != in.ActorUser {
		return Frame{}, ErrMismatch
	}
	if in.ActorUser == call.CallerUser && in.ActorDevice != call.CallerDevice {
		return Frame{}, ErrMismatch
	}
	if in.ActorUser == call.CalleeUser {
		if call.CalleeDevice == nil || *call.CalleeDevice != in.ActorDevice {
			return Frame{}, ErrMismatch
		}
	}
	revoked, err := s.revoke.DeviceRevoked(ctx, in.ActorUser, in.ActorDevice)
	if err != nil {
		return Frame{}, err
	}
	if revoked {
		return Frame{}, ErrRevoked
	}
	registered, err := s.store.KeyFor(ctx, in.ActorUser, in.ActorDevice)
	if err != nil {
		return Frame{}, err
	}
	if !bytesEqual(registered, in.CallKey) {
		return Frame{}, ErrMismatch
	}
	deadlineBase := call.CreatedAt
	if call.AcceptedAt != nil {
		deadlineBase = *call.AcceptedAt
	}
	if s.now().After(deadlineBase.Add(AuthWindow)) {
		return Frame{}, ErrInvalid
	}

	role := RoleCallee
	if in.ActorUser == call.CallerUser {
		role = RoleCaller
	}
	if in.Kind == KindHello {
		msg, err := (Hello{
			CallID: call.ID, UserID: in.ActorUser, DeviceID: in.ActorDevice, Role: role,
			Nonce: in.Nonce, CallKey: in.CallKey, MLS: in.MLS,
		}).Bytes()
		if err != nil {
			return Frame{}, err
		}
		if err := Verify(in.CallKey, msg, in.Signature); err != nil {
			return Frame{}, err
		}
	} else {
		if len(in.DTLSLocal) != FPSize || len(in.DTLSRemote) != FPSize {
			return Frame{}, ErrInvalid
		}
		frames, err := s.store.Frames(ctx, call.ID)
		if err != nil {
			return Frame{}, err
		}
		tr, err := transcriptFrom(call, frames, in)
		if err != nil {
			return Frame{}, err
		}
		msg, err := tr.Bytes()
		if err != nil {
			return Frame{}, err
		}
		if err := Verify(in.CallKey, msg, in.Signature); err != nil {
			return Frame{}, err
		}
	}

	frame := Frame{
		CallID: call.ID, SenderUser: in.ActorUser, SenderDevice: in.ActorDevice,
		Kind: in.Kind, ClientAuthID: in.ClientAuthID,
		Nonce:      append([]byte(nil), in.Nonce...),
		CallKey:    append([]byte(nil), in.CallKey...),
		MLS:        append([]byte(nil), in.MLS...),
		DTLSLocal:  append([]byte(nil), in.DTLSLocal...),
		DTLSRemote: append([]byte(nil), in.DTLSRemote...),
		Signature:  append([]byte(nil), in.Signature...),
		CreatedAt:  s.now().UTC(),
	}
	stored, _, err := s.store.PutFrame(ctx, frame)
	return stored, err
}

func (s *Service) List(ctx context.Context, actor, callID uuid.UUID) ([]Frame, error) {
	if _, err := s.calls.CallFor(ctx, actor, callID); err != nil {
		return nil, err
	}
	return s.store.Frames(ctx, callID)
}

func (s *Service) Purge(ctx context.Context, callID uuid.UUID) error {
	return s.store.Purge(ctx, callID)
}

func transcriptFrom(call CallView, frames []Frame, confirm SubmitInput) (Transcript, error) {
	var callerHello, calleeHello *Frame
	for i := range frames {
		f := &frames[i]
		if f.Kind != KindHello {
			continue
		}
		if f.SenderUser == call.CallerUser {
			callerHello = f
		}
		if f.SenderUser == call.CalleeUser {
			calleeHello = f
		}
	}
	if callerHello == nil || calleeHello == nil || call.CalleeDevice == nil {
		return Transcript{}, ErrNotReady
	}
	callerDTLS := confirm.DTLSLocal
	calleeDTLS := confirm.DTLSRemote
	if confirm.ActorUser == call.CalleeUser {
		callerDTLS = confirm.DTLSRemote
		calleeDTLS = confirm.DTLSLocal
	}
	return Transcript{
		CallID:     call.ID,
		CallerUser: call.CallerUser, CalleeUser: call.CalleeUser,
		CallerDevice: call.CallerDevice, CalleeDevice: *call.CalleeDevice,
		MediaAudio:  call.MediaAudio,
		CallerNonce: callerHello.Nonce, CalleeNonce: calleeHello.Nonce,
		CallerDTLS: callerDTLS, CalleeDTLS: calleeDTLS,
		CallerMLS: callerHello.MLS, CalleeMLS: calleeHello.MLS,
		CallerCallKey: callerHello.CallKey, CalleeCallKey: calleeHello.CallKey,
	}, nil
}
