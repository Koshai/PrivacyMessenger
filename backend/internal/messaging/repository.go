package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"

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

func orderedPair(a, b uuid.UUID) (uuid.UUID, uuid.UUID) {
	if a.String() < b.String() {
		return a, b
	}
	return b, a
}

func (r *Repository) GetOrCreateConversation(
	ctx context.Context,
	userA, userB uuid.UUID,
) (Conversation, error) {
	low, high := orderedPair(userA, userB)
	var c Conversation
	err := r.db.QueryRow(ctx, `
		INSERT INTO conversations (id, user_a, user_b)
		VALUES ($1, $2, $3)
		ON CONFLICT (user_a, user_b)
		DO UPDATE SET user_a = EXCLUDED.user_a
		RETURNING id, user_a, user_b, created_at, mls_group_id_hex, mls_initiator_id, mls_established_at
	`, uuid.New(), low, high).Scan(
		&c.ID, &c.UserA, &c.UserB, &c.CreatedAt,
		&c.MlsGroupIDHex, &c.MlsInitiatorID, &c.MlsEstablishedAt,
	)
	if err != nil {
		return Conversation{}, fmt.Errorf("get or create conversation: %w", err)
	}
	return c, nil
}

func (r *Repository) GetConversation(
	ctx context.Context,
	conversationID uuid.UUID,
) (Conversation, error) {
	var c Conversation
	err := r.db.QueryRow(ctx, `
		SELECT id, user_a, user_b, created_at, mls_group_id_hex, mls_initiator_id, mls_established_at
		FROM conversations
		WHERE id = $1
	`, conversationID).Scan(
		&c.ID, &c.UserA, &c.UserB, &c.CreatedAt,
		&c.MlsGroupIDHex, &c.MlsInitiatorID, &c.MlsEstablishedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Conversation{}, ErrConversationMissing
	}
	if err != nil {
		return Conversation{}, fmt.Errorf("get conversation: %w", err)
	}
	return c, nil
}

func (r *Repository) SetMlsGroup(
	ctx context.Context,
	conversationID, initiatorID uuid.UUID,
	groupIDHex string,
) (Conversation, error) {
	var c Conversation
	err := r.db.QueryRow(ctx, `
		UPDATE conversations
		SET mls_group_id_hex = $2,
		    mls_initiator_id = $3,
		    mls_established_at = NOW()
		WHERE id = $1
		  AND mls_group_id_hex IS NULL
		RETURNING id, user_a, user_b, created_at, mls_group_id_hex, mls_initiator_id, mls_established_at
	`, conversationID, groupIDHex, initiatorID).Scan(
		&c.ID, &c.UserA, &c.UserB, &c.CreatedAt,
		&c.MlsGroupIDHex, &c.MlsInitiatorID, &c.MlsEstablishedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		existing, getErr := r.GetConversation(ctx, conversationID)
		if getErr != nil {
			return Conversation{}, getErr
		}
		if existing.MlsGroupIDHex != nil {
			return Conversation{}, ErrMlsAlreadySet
		}
		return Conversation{}, ErrConversationMissing
	}
	if err != nil {
		return Conversation{}, fmt.Errorf("set mls group: %w", err)
	}
	return c, nil
}

func (r *Repository) InsertEnvelope(
	ctx context.Context,
	envelope Envelope,
	recipientID uuid.UUID,
) (SendResult, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return SendResult{}, err
	}
	defer tx.Rollback(ctx)

	// Idempotent fast-path before allocating a sequence number.
	existing, err := r.loadByClientID(ctx, tx, envelope.ConversationID, envelope.SenderID, envelope.ClientMessageID)
	if err == nil {
		if !bytes.Equal(existing.Ciphertext, envelope.Ciphertext) ||
			existing.ContentType != envelope.ContentType {
			return SendResult{}, ErrClientMessageIDConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return SendResult{}, err
		}
		return SendResult{Envelope: existing, Created: false}, nil
	}
	if !errors.Is(err, errEnvelopeNotInTx) {
		return SendResult{}, err
	}

	// Lock conversation row then allocate conversation_seq in the same
	// transaction as the envelope insert. Row lock serializes concurrent
	// senders so commit order matches seq order (C4).
	var convSeq int64
	err = tx.QueryRow(ctx, `
		SELECT next_envelope_seq
		FROM conversations
		WHERE id = $1
		FOR UPDATE
	`, envelope.ConversationID).Scan(&convSeq)
	if err != nil {
		return SendResult{}, fmt.Errorf("lock conversation for seq: %w", err)
	}
	err = tx.QueryRow(ctx, `
		UPDATE conversations
		SET next_envelope_seq = next_envelope_seq + 1
		WHERE id = $1
		RETURNING next_envelope_seq
	`, envelope.ConversationID).Scan(&convSeq)
	if err != nil {
		return SendResult{}, fmt.Errorf("allocate conversation seq: %w", err)
	}
	envelope.ConversationSeq = convSeq

	_, err = tx.Exec(ctx, `
		INSERT INTO message_envelopes
			(id, conversation_id, sender_id, client_message_id, ciphertext, content_type, created_at, conversation_seq)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
	`, envelope.ID, envelope.ConversationID, envelope.SenderID, envelope.ClientMessageID,
		envelope.Ciphertext, envelope.ContentType, envelope.CreatedAt, envelope.ConversationSeq)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			// Unique violation aborts the transaction; reload outside it.
			_ = tx.Rollback(ctx)
			existing, loadErr := r.loadByClientIDPool(
				ctx, envelope.ConversationID, envelope.SenderID, envelope.ClientMessageID,
			)
			if loadErr != nil {
				return SendResult{}, fmt.Errorf("insert envelope race load: %w", loadErr)
			}
			if !bytes.Equal(existing.Ciphertext, envelope.Ciphertext) ||
				existing.ContentType != envelope.ContentType {
				return SendResult{}, ErrClientMessageIDConflict
			}
			return SendResult{Envelope: existing, Created: false}, nil
		}
		return SendResult{}, fmt.Errorf("insert envelope: %w", err)
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO message_deliveries (envelope_id, recipient_id, delivered_at)
		VALUES ($1, $2, NOW())
	`, envelope.ID, recipientID)
	if err != nil {
		return SendResult{}, fmt.Errorf("insert delivery: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return SendResult{}, err
	}
	return SendResult{Envelope: envelope, Created: true}, nil
}

var errEnvelopeNotInTx = errors.New("envelope not in transaction")

func (r *Repository) loadByClientID(
	ctx context.Context,
	tx pgx.Tx,
	conversationID, senderID uuid.UUID,
	clientMessageID string,
) (Envelope, error) {
	return scanEnvelopeByClientID(ctx, tx, conversationID, senderID, clientMessageID)
}

func (r *Repository) loadByClientIDPool(
	ctx context.Context,
	conversationID, senderID uuid.UUID,
	clientMessageID string,
) (Envelope, error) {
	return scanEnvelopeByClientID(ctx, r.db, conversationID, senderID, clientMessageID)
}

type envelopeRowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func scanEnvelopeByClientID(
	ctx context.Context,
	q envelopeRowQuerier,
	conversationID, senderID uuid.UUID,
	clientMessageID string,
) (Envelope, error) {
	var e Envelope
	err := q.QueryRow(ctx, `
		SELECT id, conversation_id, sender_id, client_message_id, ciphertext, content_type, created_at,
		       COALESCE(conversation_seq, 0)
		FROM message_envelopes
		WHERE conversation_id = $1
		  AND sender_id = $2
		  AND client_message_id = $3
	`, conversationID, senderID, clientMessageID).Scan(
		&e.ID, &e.ConversationID, &e.SenderID, &e.ClientMessageID, &e.Ciphertext, &e.ContentType, &e.CreatedAt,
		&e.ConversationSeq,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Envelope{}, errEnvelopeNotInTx
	}
	if err != nil {
		return Envelope{}, fmt.Errorf("load idempotent envelope: %w", err)
	}
	return e, nil
}

func (r *Repository) ListEnvelopes(
	ctx context.Context,
	conversationID uuid.UUID,
	before *PageCursor,
	limit int,
) ([]Envelope, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	var rows pgx.Rows
	var err error
	if before == nil {
		rows, err = r.db.Query(ctx, `
			SELECT id, conversation_id, sender_id, client_message_id, ciphertext, content_type, created_at,
			       COALESCE(conversation_seq, 0)
			FROM message_envelopes
			WHERE conversation_id = $1
			ORDER BY conversation_seq DESC NULLS LAST, created_at DESC, id DESC
			LIMIT $2
		`, conversationID, limit)
	} else {
		rows, err = r.db.Query(ctx, `
			SELECT id, conversation_id, sender_id, client_message_id, ciphertext, content_type, created_at,
			       COALESCE(conversation_seq, 0)
			FROM message_envelopes
			WHERE conversation_id = $1
			  AND (created_at, id) < ($2, $3)
			ORDER BY conversation_seq DESC NULLS LAST, created_at DESC, id DESC
			LIMIT $4
		`, conversationID, before.CreatedAt, before.ID, limit)
	}
	if err != nil {
		return nil, fmt.Errorf("list envelopes: %w", err)
	}
	defer rows.Close()

	var out []Envelope
	for rows.Next() {
		var e Envelope
		if err := rows.Scan(
			&e.ID, &e.ConversationID, &e.SenderID, &e.ClientMessageID, &e.Ciphertext, &e.ContentType, &e.CreatedAt,
			&e.ConversationSeq,
		); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (r *Repository) Acknowledge(
	ctx context.Context,
	recipientID, envelopeID uuid.UUID,
) error {
	command, err := r.db.Exec(ctx, `
		UPDATE message_deliveries
		SET acknowledged_at = NOW()
		WHERE envelope_id = $1
		  AND recipient_id = $2
	`, envelopeID, recipientID)
	if err != nil {
		return fmt.Errorf("acknowledge envelope: %w", err)
	}
	if command.RowsAffected() == 0 {
		return ErrEnvelopeMissing
	}
	return nil
}

func (r *Repository) ListPendingForRecipient(
	ctx context.Context,
	recipientID uuid.UUID,
	limit int,
) ([]Envelope, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := r.db.Query(ctx, `
		SELECT e.id, e.conversation_id, e.sender_id, e.client_message_id, e.ciphertext, e.content_type, e.created_at,
		       COALESCE(e.conversation_seq, 0)
		FROM message_deliveries d
		JOIN message_envelopes e ON e.id = d.envelope_id
		WHERE d.recipient_id = $1
		  AND d.acknowledged_at IS NULL
		ORDER BY e.conversation_id ASC, e.conversation_seq ASC NULLS LAST, e.created_at ASC, e.id ASC
		LIMIT $2
	`, recipientID, limit)
	if err != nil {
		return nil, fmt.Errorf("list pending envelopes: %w", err)
	}
	defer rows.Close()

	var out []Envelope
	for rows.Next() {
		var e Envelope
		if err := rows.Scan(
			&e.ID, &e.ConversationID, &e.SenderID, &e.ClientMessageID, &e.Ciphertext, &e.ContentType, &e.CreatedAt,
			&e.ConversationSeq,
		); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
