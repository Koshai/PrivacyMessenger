package crypto

import (
	"context"
	"time"

	"github.com/google/uuid"
)

type Store interface {
	UpsertIdentity(ctx context.Context, identity DeviceIdentity) (DeviceIdentity, bool, error)
	GetIdentity(ctx context.Context, deviceID uuid.UUID) (DeviceIdentity, error)
	GetActiveIdentitiesForUser(ctx context.Context, userID uuid.UUID) ([]DeviceIdentity, error)
	RevokeIdentity(ctx context.Context, userID, deviceID uuid.UUID) error

	InsertKeyPackages(ctx context.Context, packages []KeyPackage) error
	CountAvailablePackages(ctx context.Context, deviceID uuid.UUID) (int, error)
	// ReserveOne atomically reserves one unexpired, unconsumed package for peer.
	ReserveOne(ctx context.Context, ownerUserID, requesterUserID uuid.UUID) (KeyPackage, error)
	ConsumeReserved(ctx context.Context, packageID, requesterUserID uuid.UUID) (KeyPackage, error)
	ReleaseExpiredReservations(ctx context.Context, olderThan time.Duration) (int64, error)
}

type FriendshipChecker interface {
	AreAcceptedFriends(ctx context.Context, a, b uuid.UUID) (bool, error)
}

type DeviceOwnerChecker interface {
	DeviceBelongsToUser(ctx context.Context, deviceID, userID uuid.UUID) (bool, error)
}
