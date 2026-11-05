package calling

import (
	"context"
	"errors"
	"fmt"
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

func (r *Repository) GetByID(ctx context.Context, callID uuid.UUID) (Session, error) {
	return r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at, COALESCE(version,0)
		FROM call_sessions WHERE id = $1
	`, callID)
}

func (r *Repository) GetByCallerClientID(ctx context.Context, callerUserID uuid.UUID, clientCallID string) (Session, error) {
	return r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at, COALESCE(version,0)
		FROM call_sessions
		WHERE caller_user_id = $1 AND client_call_id = $2
	`, callerUserID, clientCallID)
}

func (r *Repository) FindActiveForUser(ctx context.Context, userID uuid.UUID) (Session, bool, error) {
	session, err := r.scanOne(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at, COALESCE(version,0)
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

func (r *Repository) CreateSessionExclusive(ctx context.Context, session Session) (Session, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(ctx)

	// Serialize concurrent initiate for the same pair of users.
	a, b := session.CallerUserID, session.CalleeUserID
	if a.String() > b.String() {
		a, b = b, a
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1::text), hashtext($2::text))`, a.String(), b.String()); err != nil {
		return Session{}, err
	}

	var existingID uuid.UUID
	err = tx.QueryRow(ctx, `
		SELECT id FROM call_sessions
		WHERE caller_user_id = $1 AND client_call_id = $2
	`, session.CallerUserID, session.ClientCallID).Scan(&existingID)
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return Session{}, err
		}
		return r.GetByID(ctx, existingID)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Session{}, err
	}

	var busy bool
	err = tx.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM call_sessions
			WHERE state <> 'ended'
			  AND (
			        caller_user_id IN ($1,$2)
			     OR callee_user_id IN ($1,$2)
			  )
		)
	`, session.CallerUserID, session.CalleeUserID).Scan(&busy)
	if err != nil {
		return Session{}, err
	}
	if busy {
		return Session{}, ErrBusy
	}

	session.Version = 0
	_, err = tx.Exec(ctx, `
		INSERT INTO call_sessions (
			id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
			media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
			ring_expires_at, created_at, updated_at, accepted_at, ended_at, version
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17
		)
	`, session.ID, session.CallerUserID, session.CalleeUserID, session.CallerDeviceID, session.CalleeDeviceID,
		session.MediaType, session.State, session.EndReason, session.ClientCallID, session.SDPOffer, session.SDPAnswer,
		session.RingExpiresAt, session.CreatedAt, session.UpdatedAt, session.AcceptedAt, session.EndedAt, session.Version)
	if err != nil {
		return Session{}, fmt.Errorf("create call session: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return session, nil
}

func (r *Repository) UpdateSessionIfVersion(ctx context.Context, expectedVersion int64, session Session) (Session, error) {
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
			ended_at = $11,
			version = version + 1
		WHERE id = $1 AND version = $12
	`, session.ID, session.CalleeDeviceID, session.MediaType, session.State, session.EndReason,
		session.SDPOffer, session.SDPAnswer, session.RingExpiresAt, session.UpdatedAt,
		session.AcceptedAt, session.EndedAt, expectedVersion)
	if err != nil {
		return Session{}, fmt.Errorf("update call session: %w", err)
	}
	if tag.RowsAffected() == 0 {
		// Distinguish missing vs stale.
		if _, getErr := r.GetByID(ctx, session.ID); errors.Is(getErr, ErrCallMissing) {
			return Session{}, ErrCallMissing
		}
		return Session{}, ErrStaleUpdate
	}
	session.Version = expectedVersion + 1
	return session, nil
}

func (r *Repository) EndSessionAtomic(ctx context.Context, expectedVersion int64, session Session) (Session, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(ctx)

	tag, err := tx.Exec(ctx, `
		UPDATE call_sessions SET
			state = $2,
			end_reason = $3,
			sdp_offer = NULL,
			sdp_answer = NULL,
			updated_at = $4,
			ended_at = $5,
			version = version + 1
		WHERE id = $1 AND version = $6 AND state <> 'ended'
	`, session.ID, session.State, session.EndReason, session.UpdatedAt, session.EndedAt, expectedVersion)
	if err != nil {
		return Session{}, fmt.Errorf("end call: %w", err)
	}
	if tag.RowsAffected() == 0 {
		var curState string
		var curVersion int64
		err = tx.QueryRow(ctx, `SELECT state, version FROM call_sessions WHERE id = $1`, session.ID).
			Scan(&curState, &curVersion)
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrCallMissing
		}
		if err != nil {
			return Session{}, err
		}
		if curState == StateEnded {
			if err := tx.Commit(ctx); err != nil {
				return Session{}, err
			}
			return r.GetByID(ctx, session.ID)
		}
		return Session{}, ErrStaleUpdate
	}
	if _, err := tx.Exec(ctx, `DELETE FROM call_ice_candidates WHERE call_id = $1`, session.ID); err != nil {
		return Session{}, fmt.Errorf("%w: %v", ErrCleanupFailed, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Session{}, fmt.Errorf("%w: %v", ErrCleanupFailed, err)
	}
	session.Version = expectedVersion + 1
	session.SDPOffer = nil
	session.SDPAnswer = nil
	return session, nil
}

func (r *Repository) InsertICEExclusive(ctx context.Context, ice ICECandidate) (ICECandidate, bool, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return ICECandidate{}, false, err
	}
	defer tx.Rollback(ctx)

	var state string
	err = tx.QueryRow(ctx, `
		SELECT state FROM call_sessions WHERE id = $1 FOR UPDATE
	`, ice.CallID).Scan(&state)
	if errors.Is(err, pgx.ErrNoRows) {
		return ICECandidate{}, false, ErrCallMissing
	}
	if err != nil {
		return ICECandidate{}, false, err
	}

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

	var n int
	if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM call_ice_candidates WHERE call_id = $1`, ice.CallID).Scan(&n); err != nil {
		return ICECandidate{}, false, err
	}
	if n >= MaxICEPerCall {
		return ICECandidate{}, false, ErrPayloadTooLarge
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

func (r *Repository) ListExpiredRinging(ctx context.Context, now time.Time, limit int) ([]Session, error) {
	rows, err := r.db.Query(ctx, `
		SELECT id, caller_user_id, callee_user_id, caller_device_id, callee_device_id,
		       media_type, state, end_reason, client_call_id, sdp_offer, sdp_answer,
		       ring_expires_at, created_at, updated_at, accepted_at, ended_at, COALESCE(version,0)
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
		&s.RingExpiresAt, &s.CreatedAt, &s.UpdatedAt, &s.AcceptedAt, &s.EndedAt, &s.Version,
	)
	return s, err
}

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
