package e2e_test

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestEnvelopeIdempotencyConcurrentIdenticalAndConflict(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not configured")
	}

	ctx := context.Background()
	db, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	aliceUser := uuid.New()
	bobUser := uuid.New()
	aliceDev := uuid.New()
	bobDev := uuid.New()
	_, aliceHash := mustToken(t)
	_, bobHash := mustToken(t)

	seedUserDeviceSession(t, db, aliceUser, aliceDev, "idemp-a-"+aliceUser.String()+"@example.test", aliceHash)
	seedUserDeviceSession(t, db, bobUser, bobDev, "idemp-b-"+bobUser.String()+"@example.test", bobHash)
	seedFriendship(t, db, aliceUser, bobUser)

	repo := messaging.NewRepository(db)
	svc := messaging.NewService(repo, messaging.NewPostgresFriendshipChecker(db))
	conv, err := svc.OpenConversation(ctx, aliceUser, bobUser)
	if err != nil {
		t.Fatal(err)
	}
	groupHex := strings.ReplaceAll(uuid.New().String(), "-", "")
	if _, err := svc.EstablishMlsGroup(ctx, aliceUser, conv.ID, groupHex); err != nil {
		t.Fatal(err)
	}

	t.Run("identical concurrent replay", func(t *testing.T) {
		payload := []byte{0x42, 0x43, 0x44}
		const n = 20
		var wg sync.WaitGroup
		errs := make(chan error, n)
		ids := make(chan uuid.UUID, n)
		var createdCount atomic.Int64

		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				res, err := svc.SendEnvelope(
					ctx, aliceUser, conv.ID, "idemp-same", append([]byte(nil), payload...), messaging.ContentTypeMLSMessage,
				)
				if err != nil {
					errs <- err
					return
				}
				if !bytes.Equal(res.Envelope.Ciphertext, payload) {
					errs <- errors.New("ciphertext changed on replay")
					return
				}
				ids <- res.Envelope.ID
				if res.Created {
					createdCount.Add(1)
				}
			}()
		}
		wg.Wait()
		close(errs)
		close(ids)
		for err := range errs {
			t.Fatal(err)
		}
		if createdCount.Load() != 1 {
			t.Fatalf("expected 1 created, got %d", createdCount.Load())
		}
		var first uuid.UUID
		for id := range ids {
			if first == uuid.Nil {
				first = id
			} else if id != first {
				t.Fatal("identical concurrent replay returned different ids")
			}
		}
	})

	t.Run("conflicting concurrent ciphertext", func(t *testing.T) {
		first, err := svc.SendEnvelope(
			ctx, aliceUser, conv.ID, "idemp-conflict", []byte{0x01}, messaging.ContentTypeMLSMessage,
		)
		if err != nil || !first.Created {
			t.Fatalf("seed failed: %#v %v", first, err)
		}

		const n = 16
		var wg sync.WaitGroup
		var conflicts atomic.Int64
		errs := make(chan error, n)
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				_, err := svc.SendEnvelope(
					ctx, aliceUser, conv.ID, "idemp-conflict", []byte{byte(0x10 + i)}, messaging.ContentTypeMLSMessage,
				)
				if errors.Is(err, messaging.ErrClientMessageIDConflict) {
					conflicts.Add(1)
					return
				}
				if err != nil {
					errs <- err
				}
			}(i)
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatal(err)
		}
		if conflicts.Load() != n {
			t.Fatalf("expected %d conflicts, got %d", n, conflicts.Load())
		}

		replay, err := svc.SendEnvelope(
			ctx, aliceUser, conv.ID, "idemp-conflict", []byte{0x01}, messaging.ContentTypeMLSMessage,
		)
		if err != nil || replay.Created {
			t.Fatalf("identical replay after conflict failed: %#v %v", replay, err)
		}
		if replay.Envelope.ID != first.Envelope.ID || !bytes.Equal(replay.Envelope.Ciphertext, []byte{0x01}) {
			t.Fatal("original envelope content must be preserved")
		}
	})
}
