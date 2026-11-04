package crypto

import (
	"context"
	"time"

	"github.com/google/uuid"
)

const (
	MaxKeyPackageBytes   = 16 * 1024
	MaxPublicKeyBytes    = 512
	MaxUploadBatch       = 20
	DefaultPackageTTL    = 7 * 24 * time.Hour
	MinPackageTTL        = time.Hour
	MaxPackageTTL        = 30 * 24 * time.Hour
	TargetPackagePool    = 5
	ReservationHold      = 2 * time.Minute
)

type Service struct {
	store      Store
	friendship FriendshipChecker
	devices    DeviceOwnerChecker
	limiter    *RateLimiter
	now        func() time.Time
}

func NewService(store Store, friendship FriendshipChecker, devices DeviceOwnerChecker) *Service {
	return &Service{
		store:      store,
		friendship: friendship,
		devices:    devices,
		limiter:    NewRateLimiter(60, time.Minute),
		now:        func() time.Time { return time.Now().UTC() },
	}
}

func (s *Service) allow(userID uuid.UUID) error {
	if s.limiter != nil && !s.limiter.Allow(userID) {
		return ErrRateLimited
	}
	return nil
}

func (s *Service) RegisterIdentity(
	ctx context.Context,
	actorUserID, actorDeviceID uuid.UUID,
	publicKey []byte,
) (DeviceIdentity, bool, error) {
	if err := s.allow(actorUserID); err != nil {
		return DeviceIdentity{}, false, err
	}
	if actorUserID == uuid.Nil || actorDeviceID == uuid.Nil {
		return DeviceIdentity{}, false, ErrInvalidInput
	}
	if len(publicKey) == 0 || len(publicKey) > MaxPublicKeyBytes {
		return DeviceIdentity{}, false, ErrInvalidInput
	}

	owns, err := s.devices.DeviceBelongsToUser(ctx, actorDeviceID, actorUserID)
	if err != nil {
		return DeviceIdentity{}, false, err
	}
	if !owns {
		return DeviceIdentity{}, false, ErrNotAuthorized
	}

	now := s.now()
	identity := DeviceIdentity{
		DeviceID:          actorDeviceID,
		UserID:            actorUserID,
		PublicIdentityKey: append([]byte(nil), publicKey...),
		FingerprintHex:    FingerprintHex(publicKey),
		CreatedAt:         now,
		UpdatedAt:         now,
	}
	return s.store.UpsertIdentity(ctx, identity)
}

func (s *Service) GetPeerIdentities(
	ctx context.Context,
	actorUserID, peerUserID uuid.UUID,
) ([]DeviceIdentity, error) {
	if actorUserID == uuid.Nil || peerUserID == uuid.Nil || actorUserID == peerUserID {
		return nil, ErrInvalidInput
	}
	ok, err := s.friendship.AreAcceptedFriends(ctx, actorUserID, peerUserID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrNotAuthorized
	}
	return s.store.GetActiveIdentitiesForUser(ctx, peerUserID)
}

func (s *Service) UploadKeyPackages(
	ctx context.Context,
	actorUserID, actorDeviceID uuid.UUID,
	packages [][]byte,
	ttl time.Duration,
) error {
	if err := s.allow(actorUserID); err != nil {
		return err
	}
	if actorUserID == uuid.Nil || actorDeviceID == uuid.Nil {
		return ErrInvalidInput
	}
	if len(packages) == 0 || len(packages) > MaxUploadBatch {
		return ErrInvalidInput
	}
	if ttl == 0 {
		ttl = DefaultPackageTTL
	}
	if ttl < MinPackageTTL || ttl > MaxPackageTTL {
		return ErrInvalidInput
	}

	owns, err := s.devices.DeviceBelongsToUser(ctx, actorDeviceID, actorUserID)
	if err != nil {
		return err
	}
	if !owns {
		return ErrNotAuthorized
	}

	identity, err := s.store.GetIdentity(ctx, actorDeviceID)
	if err != nil {
		return err
	}
	if identity.RevokedAt != nil {
		return ErrIdentityRevoked
	}
	if identity.UserID != actorUserID {
		return ErrNotAuthorized
	}

	now := s.now()
	rows := make([]KeyPackage, 0, len(packages))
	for _, pkg := range packages {
		if len(pkg) == 0 || len(pkg) > MaxKeyPackageBytes {
			return ErrInvalidInput
		}
		rows = append(rows, KeyPackage{
			ID:         uuid.New(),
			DeviceID:   actorDeviceID,
			UserID:     actorUserID,
			KeyPackage: append([]byte(nil), pkg...),
			CreatedAt:  now,
			ExpiresAt:  now.Add(ttl),
		})
	}
	return s.store.InsertKeyPackages(ctx, rows)
}

// ClaimKeyPackage reserves then consumes a one-time package for a friend.
func (s *Service) ClaimKeyPackage(
	ctx context.Context,
	actorUserID, peerUserID uuid.UUID,
) (KeyPackage, DeviceIdentity, error) {
	if err := s.allow(actorUserID); err != nil {
		return KeyPackage{}, DeviceIdentity{}, err
	}
	if actorUserID == uuid.Nil || peerUserID == uuid.Nil || actorUserID == peerUserID {
		return KeyPackage{}, DeviceIdentity{}, ErrInvalidInput
	}
	ok, err := s.friendship.AreAcceptedFriends(ctx, actorUserID, peerUserID)
	if err != nil {
		return KeyPackage{}, DeviceIdentity{}, err
	}
	if !ok {
		return KeyPackage{}, DeviceIdentity{}, ErrNotAuthorized
	}

	_, _ = s.store.ReleaseExpiredReservations(ctx, ReservationHold)

	reserved, err := s.store.ReserveOne(ctx, peerUserID, actorUserID)
	if err != nil {
		return KeyPackage{}, DeviceIdentity{}, err
	}

	consumed, err := s.store.ConsumeReserved(ctx, reserved.ID, actorUserID)
	if err != nil {
		return KeyPackage{}, DeviceIdentity{}, err
	}

	identity, err := s.store.GetIdentity(ctx, consumed.DeviceID)
	if err != nil {
		return KeyPackage{}, DeviceIdentity{}, err
	}
	if identity.RevokedAt != nil {
		return KeyPackage{}, DeviceIdentity{}, ErrIdentityRevoked
	}

	return consumed, identity, nil
}

func (s *Service) PackagePoolStatus(
	ctx context.Context,
	actorUserID, actorDeviceID uuid.UUID,
) (available int, needsReplenish bool, err error) {
	owns, err := s.devices.DeviceBelongsToUser(ctx, actorDeviceID, actorUserID)
	if err != nil {
		return 0, false, err
	}
	if !owns {
		return 0, false, ErrNotAuthorized
	}
	n, err := s.store.CountAvailablePackages(ctx, actorDeviceID)
	if err != nil {
		return 0, false, err
	}
	return n, n < TargetPackagePool, nil
}

func (s *Service) RevokeDevice(
	ctx context.Context,
	actorUserID, deviceID uuid.UUID,
) error {
	owns, err := s.devices.DeviceBelongsToUser(ctx, deviceID, actorUserID)
	if err != nil {
		return err
	}
	if !owns {
		return ErrNotAuthorized
	}
	return s.store.RevokeIdentity(ctx, actorUserID, deviceID)
}
