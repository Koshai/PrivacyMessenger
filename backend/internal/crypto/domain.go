package crypto

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrInvalidInput       = errors.New("invalid crypto input")
	ErrNotAuthorized      = errors.New("not authorized for device crypto")
	ErrIdentityMissing    = errors.New("mls identity not registered")
	ErrIdentityRevoked    = errors.New("mls identity revoked")
	ErrIdentityMismatch   = errors.New("public identity key mismatch")
	ErrNoKeyPackage       = errors.New("no key package available")
	ErrPackageUnavailable = errors.New("key package unavailable")
	ErrRateLimited        = errors.New("crypto rate limited")
	ErrDeviceRevoked      = errors.New("device crypto revoked")
)

type DeviceIdentity struct {
	DeviceID          uuid.UUID
	UserID            uuid.UUID
	PublicIdentityKey []byte
	FingerprintHex    string
	CreatedAt         time.Time
	UpdatedAt         time.Time
	RevokedAt         *time.Time
}

type KeyPackage struct {
	ID               uuid.UUID
	DeviceID         uuid.UUID
	UserID           uuid.UUID
	KeyPackage       []byte
	CreatedAt        time.Time
	ExpiresAt        time.Time
	ConsumedAt       *time.Time
	ReservedAt       *time.Time
	ReservedByUserID *uuid.UUID
}

type KeyChangeNotice struct {
	UserID         uuid.UUID
	DeviceID       uuid.UUID
	FingerprintHex string
	ChangedAt      time.Time
}
