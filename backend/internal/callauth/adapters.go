package callauth

import (
	"context"
	"errors"

	"example.com/private-messenger/backend/internal/calling"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CallingBridge adapts the calling service into a call-auth lookup.
type CallingBridge struct {
	Get func(ctx context.Context, actor, callID uuid.UUID) (calling.Session, error)
}

func (b CallingBridge) CallFor(ctx context.Context, actor, callID uuid.UUID) (CallView, error) {
	session, err := b.Get(ctx, actor, callID)
	if err != nil {
		return CallView{}, err
	}
	return CallView{
		ID: session.ID, CallerUser: session.CallerUserID, CalleeUser: session.CalleeUserID,
		CallerDevice: session.CallerDeviceID, CalleeDevice: session.CalleeDeviceID,
		MediaAudio: session.MediaType == calling.MediaAudio,
		Ended:      session.State == calling.StateEnded,
		AcceptedAt: session.AcceptedAt, CreatedAt: session.CreatedAt,
	}, nil
}

// PostgresRevocation reads device_mls_identities. Missing or revoked identities fail closed.
type PostgresRevocation struct{ db *pgxpool.Pool }

func NewPostgresRevocation(db *pgxpool.Pool) *PostgresRevocation {
	return &PostgresRevocation{db: db}
}

func (p *PostgresRevocation) DeviceRevoked(ctx context.Context, userID, deviceID uuid.UUID) (bool, error) {
	var revoked bool
	err := p.db.QueryRow(ctx, `
		SELECT revoked_at IS NOT NULL
		FROM device_mls_identities
		WHERE device_id=$1 AND user_id=$2
	`, deviceID, userID).Scan(&revoked)
	if errors.Is(err, pgx.ErrNoRows) {
		return true, nil
	}
	return revoked, err
}
