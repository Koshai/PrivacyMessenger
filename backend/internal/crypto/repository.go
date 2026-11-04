package crypto

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository struct {
	db *pgxpool.Pool
}

func NewRepository(db *pgxpool.Pool) *Repository {
	return &Repository{db: db}
}

func (r *Repository) UpsertIdentity(ctx context.Context, identity DeviceIdentity) (DeviceIdentity, bool, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return DeviceIdentity{}, false, err
	}
	defer tx.Rollback(ctx)

	var existing DeviceIdentity
	var revokedAt *time.Time
	err = tx.QueryRow(ctx, `
		SELECT device_id, user_id, public_identity_key, fingerprint_hex, created_at, updated_at, revoked_at
		FROM device_mls_identities WHERE device_id = $1 FOR UPDATE
	`, identity.DeviceID).Scan(
		&existing.DeviceID, &existing.UserID, &existing.PublicIdentityKey, &existing.FingerprintHex,
		&existing.CreatedAt, &existing.UpdatedAt, &revokedAt,
	)
	if err == nil {
		existing.RevokedAt = revokedAt
		if existing.RevokedAt != nil {
			return DeviceIdentity{}, false, ErrIdentityRevoked
		}
		if !bytesEqual(existing.PublicIdentityKey, identity.PublicIdentityKey) {
			return DeviceIdentity{}, false, ErrIdentityMismatch
		}
		_, err = tx.Exec(ctx, `
			UPDATE device_mls_identities SET updated_at = $2 WHERE device_id = $1
		`, identity.DeviceID, identity.UpdatedAt)
		if err != nil {
			return DeviceIdentity{}, false, err
		}
		if err := tx.Commit(ctx); err != nil {
			return DeviceIdentity{}, false, err
		}
		existing.UpdatedAt = identity.UpdatedAt
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return DeviceIdentity{}, false, err
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO device_mls_identities
			(device_id, user_id, public_identity_key, fingerprint_hex, created_at, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6)
	`, identity.DeviceID, identity.UserID, identity.PublicIdentityKey, identity.FingerprintHex,
		identity.CreatedAt, identity.UpdatedAt)
	if err != nil {
		return DeviceIdentity{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return DeviceIdentity{}, false, err
	}
	return identity, true, nil
}

func (r *Repository) GetIdentity(ctx context.Context, deviceID uuid.UUID) (DeviceIdentity, error) {
	var id DeviceIdentity
	var revokedAt *time.Time
	err := r.db.QueryRow(ctx, `
		SELECT device_id, user_id, public_identity_key, fingerprint_hex, created_at, updated_at, revoked_at
		FROM device_mls_identities WHERE device_id = $1
	`, deviceID).Scan(
		&id.DeviceID, &id.UserID, &id.PublicIdentityKey, &id.FingerprintHex,
		&id.CreatedAt, &id.UpdatedAt, &revokedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceIdentity{}, ErrIdentityMissing
	}
	if err != nil {
		return DeviceIdentity{}, err
	}
	id.RevokedAt = revokedAt
	return id, nil
}

func (r *Repository) GetActiveIdentitiesForUser(ctx context.Context, userID uuid.UUID) ([]DeviceIdentity, error) {
	rows, err := r.db.Query(ctx, `
		SELECT device_id, user_id, public_identity_key, fingerprint_hex, created_at, updated_at, revoked_at
		FROM device_mls_identities
		WHERE user_id = $1 AND revoked_at IS NULL
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]DeviceIdentity, 0)
	for rows.Next() {
		var id DeviceIdentity
		var revokedAt *time.Time
		if err := rows.Scan(
			&id.DeviceID, &id.UserID, &id.PublicIdentityKey, &id.FingerprintHex,
			&id.CreatedAt, &id.UpdatedAt, &revokedAt,
		); err != nil {
			return nil, err
		}
		id.RevokedAt = revokedAt
		out = append(out, id)
	}
	return out, rows.Err()
}

func (r *Repository) RevokeIdentity(ctx context.Context, userID, deviceID uuid.UUID) error {
	tag, err := r.db.Exec(ctx, `
		UPDATE device_mls_identities
		SET revoked_at = NOW(), updated_at = NOW()
		WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL
	`, deviceID, userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrIdentityMissing
	}
	return nil
}

func (r *Repository) InsertKeyPackages(ctx context.Context, packages []KeyPackage) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	for _, p := range packages {
		_, err := tx.Exec(ctx, `
			INSERT INTO mls_key_packages
				(id, device_id, user_id, key_package, created_at, expires_at)
			VALUES ($1,$2,$3,$4,$5,$6)
		`, p.ID, p.DeviceID, p.UserID, p.KeyPackage, p.CreatedAt, p.ExpiresAt)
		if err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (r *Repository) CountAvailablePackages(ctx context.Context, deviceID uuid.UUID) (int, error) {
	var n int
	err := r.db.QueryRow(ctx, `
		SELECT COUNT(*) FROM mls_key_packages
		WHERE device_id = $1
		  AND consumed_at IS NULL
		  AND reserved_at IS NULL
		  AND expires_at > NOW()
	`, deviceID).Scan(&n)
	return n, err
}

func (r *Repository) ReserveOne(ctx context.Context, ownerUserID, requesterUserID uuid.UUID) (KeyPackage, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return KeyPackage{}, err
	}
	defer tx.Rollback(ctx)

	var p KeyPackage
	err = tx.QueryRow(ctx, `
		SELECT id, device_id, user_id, key_package, created_at, expires_at
		FROM mls_key_packages
		WHERE user_id = $1
		  AND consumed_at IS NULL
		  AND reserved_at IS NULL
		  AND expires_at > NOW()
		ORDER BY created_at ASC
		FOR UPDATE SKIP LOCKED
		LIMIT 1
	`, ownerUserID).Scan(
		&p.ID, &p.DeviceID, &p.UserID, &p.KeyPackage, &p.CreatedAt, &p.ExpiresAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return KeyPackage{}, ErrNoKeyPackage
	}
	if err != nil {
		return KeyPackage{}, err
	}

	_, err = tx.Exec(ctx, `
		UPDATE mls_key_packages
		SET reserved_at = NOW(), reserved_by_user_id = $2
		WHERE id = $1
	`, p.ID, requesterUserID)
	if err != nil {
		return KeyPackage{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return KeyPackage{}, err
	}
	now := time.Now().UTC()
	p.ReservedAt = &now
	p.ReservedByUserID = &requesterUserID
	return p, nil
}

func (r *Repository) ConsumeReserved(ctx context.Context, packageID, requesterUserID uuid.UUID) (KeyPackage, error) {
	var p KeyPackage
	var consumedAt, reservedAt *time.Time
	var reservedBy *uuid.UUID
	err := r.db.QueryRow(ctx, `
		UPDATE mls_key_packages
		SET consumed_at = NOW()
		WHERE id = $1
		  AND reserved_by_user_id = $2
		  AND consumed_at IS NULL
		RETURNING id, device_id, user_id, key_package, created_at, expires_at,
		          consumed_at, reserved_at, reserved_by_user_id
	`, packageID, requesterUserID).Scan(
		&p.ID, &p.DeviceID, &p.UserID, &p.KeyPackage, &p.CreatedAt, &p.ExpiresAt,
		&consumedAt, &reservedAt, &reservedBy,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return KeyPackage{}, ErrPackageUnavailable
	}
	if err != nil {
		return KeyPackage{}, err
	}
	p.ConsumedAt = consumedAt
	p.ReservedAt = reservedAt
	p.ReservedByUserID = reservedBy
	return p, nil
}

func (r *Repository) ReleaseExpiredReservations(ctx context.Context, olderThan time.Duration) (int64, error) {
	secs := int(olderThan.Seconds())
	if secs < 1 {
		secs = 1
	}
	tag, err := r.db.Exec(ctx, `
		UPDATE mls_key_packages
		SET reserved_at = NULL, reserved_by_user_id = NULL
		WHERE reserved_at IS NOT NULL
		  AND consumed_at IS NULL
		  AND reserved_at < NOW() - make_interval(secs => $1)
	`, secs)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

type PostgresDeviceOwnerChecker struct {
	db *pgxpool.Pool
}

func NewPostgresDeviceOwnerChecker(db *pgxpool.Pool) *PostgresDeviceOwnerChecker {
	return &PostgresDeviceOwnerChecker{db: db}
}

func (c *PostgresDeviceOwnerChecker) DeviceBelongsToUser(ctx context.Context, deviceID, userID uuid.UUID) (bool, error) {
	var found bool
	err := c.db.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM devices WHERE id = $1 AND user_id = $2
		)
	`, deviceID, userID).Scan(&found)
	return found, err
}
