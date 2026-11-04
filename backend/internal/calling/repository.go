package calling

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository struct {
	db *pgxpool.Pool
}

func NewRepository(db *pgxpool.Pool) *Repository {
	return &Repository{db: db}
}

func (r *Repository) CreateSession(ctx context.Context, session Session) (Session, error) {
	_, err := r.db.Exec(ctx, `
		INSERT INTO call_sessions (
			id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
			media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
			ring_expires_at, created_at, updated_at, accepted_at, ended_at
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
		)
	`, session.ID, session.CallerUserID, session.CalleeUserID, session.CallerDeviceID, session.CalleeDeviceID,
		session.MediaType, session.State, session.EndReason, session.ClientCallID, session.SDPOffer, session.SDPAnswer,
		session.RingExpiresAt, session.CreatedAt, session.UpdatedAt, session.AcceptedAt, session.EndedAt)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			existing, getErr := r.GetByCallerClientID(ctx, session.CallerUserID, session.ClientCallID)
			if getErr == nil {
				return existing, nil
			}
		}
		return Session{}, fmt.Errorf("create call session: %w", err)
	}
	return session, nil
}

func (r *Repository) GetByID(ctx context.Context, callID uuid.UUID) (Session, error) {
	return r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at
		FROM call_sessions WHERE id = $1
	`, callID)
}

func (r *Repository) GetByCallerClientID(ctx context.Context, callerUserID uuid.UUID, clientCallID string) (Session, error) {
	return r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at
		FROM call_sessions
		WHERE caller_user_id = $1 AND client_call_id = $2
	`, callerUserID, clientCallID)
}

func (r *Repository) FindActiveForUser(ctx context.Context, userID uuid.UUID) (Session, bool, error) {
	session, err := r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at
		FROM call_sessions
		WHERE state <> 'ended'
		  AND (caller_user_id = $1 OR callee_user_id = $1)
		ORDER BY created_at DESC
		LIMIT 1
	`, userID)
	if errors.Is(err, ErrCallMissing) {
		return Session{}, false, nil
	}
	if err != nil {
		return Session{}, false, err
	}
	return session, true, nil
}

func (r *Repository) UpdateSession(ctx context.Context, session Session) (Session, error) {
	tag, err := r.db.Exec(ctx, `
		UPDATE call_sessions SET
			callee_device_id = $2,
			media_type = $3,
			state = $4,
			end_reason = $5,
			sdp_offer = $6,
			sdp_answer = $7,
			ring_expires_at = $8,
			updated_at = $9,
			accepted_at = $10,
			ended_at = $11
		WHERE id = $1
	`, session.ID, session.CalleeDeviceID, session.MediaType, session.State, session.EndReason,
		session.SDPOffer, session.SDPAnswer, session.RingExpiresAt, session.UpdatedAt,
		session.AcceptedAt, session.EndedAt)
	if err != nil {
		return Session{}, fmt.Errorf("update call session: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return Session{}, ErrCallMissing
	}
	return session, nil
}

func (r *Repository) ClearSignaling(ctx context.Context, callID uuid.UUID) error {
	_, err := r.db.Exec(ctx, `
		UPDATE call_sessions
		SET sdp_offer = NULL, sdp_answer = NULL, updated_at = NOW()
		WHERE id = $1
	`, callID)
	return err
}

func (r *Repository) InsertICE(ctx context.Context, ice ICECandidate) (ICECandidate, bool, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return ICECandidate{}, false, err
	}
	defer tx.Rollback(ctx)

	var existing ICECandidate
	err = tx.QueryRow(ctx, `
		SELECT id, call_id, sender_user_id, seq, candidate, sdp_mid, sdp_mline_index, client_ice_id, created_at
		FROM call_ice_candidates
		WHERE call_id = $1 AND sender_user_id = $2 AND client_ice_id = $3
	`, ice.CallID, ice.SenderUserID, ice.ClientICEID).Scan(
		&existing.ID, &existing.CallID, &existing.SenderUserID, &existing.Seq, &existing.Candidate,
		&existing.SDPMID, &existing.SDPMLineIndex, &existing.ClientICEID, &existing.CreatedAt,
	)
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return ICECandidate{}, false, err
		}
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return ICECandidate{}, false, err
	}

	var seq int64
	err = tx.QueryRow(ctx, `
		SELECT COALESCE(MAX(seq), 0) + 1 FROM call_ice_candidates WHERE call_id = $1
	`, ice.CallID).Scan(&seq)
	if err != nil {
		return ICECandidate{}, false, err
	}
	ice.Seq = seq
	_, err = tx.Exec(ctx, `
		INSERT INTO call_ice_candidates (
			id, call_id, sender_user_id, seq, candidate, sdp_mid, sdp_mline_index, client_ice_id, created_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
	`, ice.ID, ice.CallID, ice.SenderUserID, ice.Seq, ice.Candidate, ice.SDPMID, ice.SDPMLineIndex, ice.ClientICEID, ice.CreatedAt)
	if err != nil {
		return ICECandidate{}, false, fmt.Errorf("insert ice: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return ICECandidate{}, false, err
	}
	return ice, true, nil
}

func (r *Repository) ListICEAfter(ctx context.Context, callID uuid.UUID, afterSeq int64, limit int) ([]ICECandidate, error) {
	rows, err := r.db.Query(ctx, `
		SELECT id, call_id, sender_user_id, seq, candidate, sdp_mid, sdp_mline_index, client_ice_id, created_at
		FROM call_ice_candidates
		WHERE call_id = $1 AND seq > $2
		ORDER BY seq ASC
		LIMIT $3
	`, callID, afterSeq, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ICECandidate, 0)
	for rows.Next() {
		var ice ICECandidate
		if err := rows.Scan(
			&ice.ID, &ice.CallID, &ice.SenderUserID, &ice.Seq, &ice.Candidate,
			&ice.SDPMID, &ice.SDPMLineIndex, &ice.ClientICEID, &ice.CreatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, ice)
	}
	return out, rows.Err()
}

func (r *Repository) DeleteICEForCall(ctx context.Context, callID uuid.UUID) error {
	_, err := r.db.Exec(ctx, `DELETE FROM call_ice_candidates WHERE call_id = $1`, callID)
	return err
}

func (r *Repository) ListExpiredRinging(ctx context.Context, now time.Time, limit int) ([]Session, error) {
	rows, err := r.db.Query(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at
		FROM call_sessions
		WHERE state = 'ringing' AND ring_expires_at <= $1
		ORDER BY ring_expires_at ASC
		LIMIT $2
	`, now, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Session, 0)
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (r *Repository) CountICE(ctx context.Context, callID uuid.UUID) (int, error) {
	var n int
	err := r.db.QueryRow(ctx, `SELECT COUNT(*) FROM call_ice_candidates WHERE call_id = $1`, callID).Scan(&n)
	return n, err
}

type scannable interface {
	Scan(dest ...any) error
}

func (r *Repository) scanOne(ctx context.Context, sql string, args ...any) (Session, error) {
	row := r.db.QueryRow(ctx, sql, args...)
	s, err := scanSession(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Session{}, ErrCallMissing
	}
	return s, err
}

func scanSession(row scannable) (Session, error) {
	var s Session
	err := row.Scan(
		&s.ID, &s.CallerUserID, &s.CalleeUserID, &s.CallerDeviceID, &s.CalleeDeviceID,
		&s.MediaType, &s.State, &s.EndReason, &s.ClientCallID, &s.SDPOffer, &s.SDPAnswer,
		&s.RingExpiresAt, &s.CreatedAt, &s.UpdatedAt, &s.AcceptedAt, &s.EndedAt,
	)
	return s, err
}

// PostgresBlockChecker adapts user_blocks for calling authorization.
type PostgresBlockChecker struct {
	db *pgxpool.Pool
}

func NewPostgresBlockChecker(db *pgxpool.Pool) *PostgresBlockChecker {
	return &PostgresBlockChecker{db: db}
}

func (c *PostgresBlockChecker) IsBlockedEitherWay(ctx context.Context, a, b uuid.UUID) (bool, error) {
	var exists bool
	err := c.db.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM user_blocks
			WHERE (blocker_id = $1 AND blocked_id = $2)
			   OR (blocker_id = $2 AND blocked_id = $1)
		)
	`, a, b).Scan(&exists)
	return exists, err
}
