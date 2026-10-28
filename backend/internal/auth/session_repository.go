package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrInvalidSession = errors.New("invalid or expired session")

type AuthenticatedSession struct {
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	ExpiresAt time.Time
}

type SessionRepository struct {
	db *pgxpool.Pool
}

func NewSessionRepository(
	db *pgxpool.Pool,
) *SessionRepository {
	return &SessionRepository{db: db}
}

func (r *SessionRepository) Authenticate(
	ctx context.Context,
	token string,
) (AuthenticatedSession, error) {
	if token == "" {
		return AuthenticatedSession{}, ErrInvalidSession
	}

	// Check that the token has the expected format.
	// Session tokens are 32 random bytes encoded with
	// unpadded URL-safe Base64.
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(decoded) != SessionTokenBytes {
		return AuthenticatedSession{}, ErrInvalidSession
	}

	hash := HashSessionToken(token)

	var session AuthenticatedSession

	err = r.db.QueryRow(ctx, `
		SELECT s.user_id, s.device_id, s.expires_at
		FROM sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1
		  AND s.revoked_at IS NULL
		  AND s.expires_at > NOW()
		  AND u.deleted_at IS NULL
	`, hash[:]).Scan(
		&session.UserID,
		&session.DeviceID,
		&session.ExpiresAt,
	)

	if errors.Is(err, pgx.ErrNoRows) {
		return AuthenticatedSession{}, ErrInvalidSession
	}
	if err != nil {
		return AuthenticatedSession{}, err
	}

	return session, nil
}

func (r *SessionRepository) Revoke(
	ctx context.Context,
	token string,
) error {
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(decoded) != 32 {
		return ErrInvalidSession
	}

	hash := HashSessionToken(token)

	command, err := r.db.Exec(ctx, `
		UPDATE sessions
		SET revoked_at = NOW()
		WHERE token_hash = $1
		  AND revoked_at IS NULL
		  AND expires_at > NOW()
	`, hash[:])

	if err != nil {
		return err
	}

	if command.RowsAffected() == 0 {
		return ErrInvalidSession
	}

	return nil
}
