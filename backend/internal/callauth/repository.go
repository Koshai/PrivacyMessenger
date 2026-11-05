package callauth

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository struct{ db *pgxpool.Pool }

func NewRepository(db *pgxpool.Pool) *Repository { return &Repository{db: db} }

func (r *Repository) RegisterKey(ctx context.Context, userID, deviceID uuid.UUID, publicKey []byte) error {
	tag, err := r.db.Exec(ctx, `
		INSERT INTO device_call_auth_keys (device_id, user_id, public_key)
		VALUES ($1,$2,$3)
		ON CONFLICT (device_id) DO NOTHING
	`, deviceID, userID, publicKey)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	var existing []byte
	if err := r.db.QueryRow(ctx, `SELECT public_key FROM device_call_auth_keys WHERE device_id=$1 AND user_id=$2`, deviceID, userID).Scan(&existing); err != nil {
		return ErrReplay
	}
	if !bytesEqual(existing, publicKey) {
		return ErrReplay
	}
	return nil
}

func (r *Repository) KeyFor(ctx context.Context, userID, deviceID uuid.UUID) ([]byte, error) {
	var key []byte
	err := r.db.QueryRow(ctx, `SELECT public_key FROM device_call_auth_keys WHERE device_id=$1 AND user_id=$2`, deviceID, userID).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrInvalid
	}
	return key, err
}

func (r *Repository) PutFrame(ctx context.Context, frame Frame) (Frame, bool, error) {
	_, err := r.db.Exec(ctx, `
		INSERT INTO call_auth_frames (
			call_id, sender_user_id, sender_device_id, kind, client_auth_id,
			nonce, call_public_key, mls_fingerprint, dtls_local, dtls_remote, signature
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
	`, frame.CallID, frame.SenderUser, frame.SenderDevice, frame.Kind, frame.ClientAuthID,
		frame.Nonce, frame.CallKey, frame.MLS, nilIfEmpty(frame.DTLSLocal), nilIfEmpty(frame.DTLSRemote), frame.Signature)
	if err == nil {
		return frame, true, nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		existing, getErr := r.frameByClientID(ctx, frame.ClientAuthID)
		if getErr != nil {
			return Frame{}, false, ErrReplay
		}
		if sameFrame(existing, frame) {
			return existing, false, nil
		}
		return Frame{}, false, ErrReplay
	}
	return Frame{}, false, err
}

func (r *Repository) frameByClientID(ctx context.Context, id string) (Frame, error) {
	rows, err := r.db.Query(ctx, frameSelect+` WHERE client_auth_id=$1`, id)
	if err != nil {
		return Frame{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return Frame{}, ErrInvalid
	}
	return scanFrame(rows)
}

func (r *Repository) Frames(ctx context.Context, callID uuid.UUID) ([]Frame, error) {
	rows, err := r.db.Query(ctx, frameSelect+` WHERE call_id=$1 ORDER BY created_at`, callID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Frame
	for rows.Next() {
		f, err := scanFrame(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (r *Repository) Purge(ctx context.Context, callID uuid.UUID) error {
	_, err := r.db.Exec(ctx, `DELETE FROM call_auth_frames WHERE call_id=$1`, callID)
	return err
}

const frameSelect = `
	SELECT call_id, sender_user_id, sender_device_id, kind, client_auth_id,
		nonce, call_public_key, mls_fingerprint, dtls_local, dtls_remote, signature, created_at
	FROM call_auth_frames`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanFrame(row rowScanner) (Frame, error) {
	var f Frame
	var local, remote []byte
	if err := row.Scan(&f.CallID, &f.SenderUser, &f.SenderDevice, &f.Kind, &f.ClientAuthID,
		&f.Nonce, &f.CallKey, &f.MLS, &local, &remote, &f.Signature, &f.CreatedAt); err != nil {
		return Frame{}, err
	}
	f.DTLSLocal, f.DTLSRemote = local, remote
	return f, nil
}

func nilIfEmpty(b []byte) []byte {
	if len(b) == 0 {
		return nil
	}
	return b
}
