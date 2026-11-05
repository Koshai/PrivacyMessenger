// Package callauth implements the D4 call-authentication transcript.
// The server relays frames and checks membership, revocation, and self-signatures.
// Peers verify the transcript against pinned device keys and the DTLS fingerprint
// of the WebRTC association they actually negotiated.
package callauth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

const (
	ProtocolVersion = 1
	KeySize         = ed25519.PublicKeySize
	SigSize         = ed25519.SignatureSize
	NonceSize       = 32
	FPSize          = 32

	RoleCaller byte = 1
	RoleCallee byte = 2

	KindHello   = "hello"
	KindConfirm = "confirm"
)

var (
	helloDomain   = []byte("PrivacyMessenger/call-hello/v1\n")
	confirmDomain = []byte("PrivacyMessenger/call-auth/v1\n")

	ErrInvalid  = errors.New("invalid call auth")
	ErrReplay   = errors.New("replayed call auth")
	ErrRevoked  = errors.New("call auth device revoked")
	ErrMismatch = errors.New("call auth mismatch")
	ErrNotReady = errors.New("call auth not ready")
)

// Transcript is the canonical call context both parties sign.
type Transcript struct {
	CallID        uuid.UUID
	CallerUser    uuid.UUID
	CalleeUser    uuid.UUID
	CallerDevice  uuid.UUID
	CalleeDevice  uuid.UUID
	MediaAudio    bool
	CallerNonce   []byte
	CalleeNonce   []byte
	CallerDTLS    []byte
	CalleeDTLS    []byte
	CallerMLS     []byte
	CalleeMLS     []byte
	CallerCallKey []byte
	CalleeCallKey []byte
}

// Hello binds a fresh nonce to the signing device before DTLS fingerprints exist.
type Hello struct {
	CallID   uuid.UUID
	UserID   uuid.UUID
	DeviceID uuid.UUID
	Role     byte
	Nonce    []byte
	CallKey  []byte
	MLS      []byte
}

func (h Hello) Bytes() ([]byte, error) {
	if err := h.validate(); err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(helloDomain)+16*3+1+NonceSize+KeySize+FPSize)
	out = append(out, helloDomain...)
	out = append(out, h.CallID[:]...)
	out = append(out, h.UserID[:]...)
	out = append(out, h.DeviceID[:]...)
	out = append(out, h.Role)
	out = append(out, h.Nonce...)
	out = append(out, h.CallKey...)
	out = append(out, h.MLS...)
	return out, nil
}

func (h Hello) validate() error {
	if h.Role != RoleCaller && h.Role != RoleCallee {
		return ErrInvalid
	}
	if len(h.Nonce) != NonceSize || len(h.CallKey) != KeySize || len(h.MLS) != FPSize {
		return ErrInvalid
	}
	if h.CallID == uuid.Nil || h.UserID == uuid.Nil || h.DeviceID == uuid.Nil {
		return ErrInvalid
	}
	return nil
}

func (t Transcript) Bytes() ([]byte, error) {
	if len(t.CallerNonce) != NonceSize || len(t.CalleeNonce) != NonceSize ||
		len(t.CallerDTLS) != FPSize || len(t.CalleeDTLS) != FPSize ||
		len(t.CallerMLS) != FPSize || len(t.CalleeMLS) != FPSize ||
		len(t.CallerCallKey) != KeySize || len(t.CalleeCallKey) != KeySize {
		return nil, ErrInvalid
	}
	if t.CallID == uuid.Nil || t.CallerUser == uuid.Nil || t.CalleeUser == uuid.Nil ||
		t.CallerDevice == uuid.Nil || t.CalleeDevice == uuid.Nil {
		return nil, ErrInvalid
	}
	media := byte(2)
	if t.MediaAudio {
		media = 1
	}
	out := make([]byte, 0, 256)
	out = append(out, confirmDomain...)
	out = append(out, ProtocolVersion)
	out = append(out, t.CallID[:]...)
	out = append(out, t.CallerUser[:]...)
	out = append(out, t.CalleeUser[:]...)
	out = append(out, t.CallerDevice[:]...)
	out = append(out, t.CalleeDevice[:]...)
	out = append(out, media)
	out = append(out, t.CallerNonce...)
	out = append(out, t.CalleeNonce...)
	out = append(out, t.CallerDTLS...)
	out = append(out, t.CalleeDTLS...)
	out = append(out, t.CallerMLS...)
	out = append(out, t.CalleeMLS...)
	out = append(out, t.CallerCallKey...)
	out = append(out, t.CalleeCallKey...)
	return out, nil
}

func Sign(private ed25519.PrivateKey, msg []byte) ([]byte, error) {
	if len(private) != ed25519.PrivateKeySize {
		return nil, ErrInvalid
	}
	return ed25519.Sign(private, msg), nil
}

func Verify(public, msg, sig []byte) error {
	if len(public) != KeySize || len(sig) != SigSize {
		return ErrInvalid
	}
	if !ed25519.Verify(public, msg, sig) {
		return fmt.Errorf("%w: signature", ErrMismatch)
	}
	return nil
}

func NewNonce() ([]byte, error) {
	b := make([]byte, NonceSize)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// VerifyPeerConfirm checks a peer signature against the pinned call key and the
// DTLS fingerprint observed on the local peer connection (not the signaling copy alone).
func VerifyPeerConfirm(pinnedCallKey, observedRemoteDTLS []byte, transcript Transcript, peerIsCaller bool, sig []byte) error {
	msg, err := transcript.Bytes()
	if err != nil {
		return err
	}
	if err := Verify(pinnedCallKey, msg, sig); err != nil {
		return err
	}
	var signedSelf []byte
	if peerIsCaller {
		signedSelf = transcript.CallerDTLS
	} else {
		signedSelf = transcript.CalleeDTLS
	}
	if len(observedRemoteDTLS) != FPSize || !bytesEqual(signedSelf, observedRemoteDTLS) {
		return fmt.Errorf("%w: dtls fingerprint", ErrMismatch)
	}
	return nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := range a {
		v |= a[i] ^ b[i]
	}
	return v == 0
}
