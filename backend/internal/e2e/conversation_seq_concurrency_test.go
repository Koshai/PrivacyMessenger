package e2e_test

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"

	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Concurrent senders must receive unique, gap-free conversation_seq values
// because allocation is locked in the same transaction as insert.
func TestConversationSeqConcurrentAllocation(t *testing.T) {
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
	aliceToken, aliceHash := mustToken(t)
	bobToken, bobHash := mustToken(t)
	_ = aliceToken
	_ = bobToken

	seedUserDeviceSession(t, db, aliceUser, aliceDev, "seq-a-"+aliceUser.String()+"@example.test", aliceHash)
	seedUserDeviceSession(t, db, bobUser, bobDev, "seq-b-"+bobUser.String()+"@example.test", bobHash)
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

	const n = 20
	var wg sync.WaitGroup
	errs := make(chan error, n)
	results := make(chan int64, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			res, err := svc.SendEnvelope(
				ctx,
				aliceUser,
				conv.ID,
				uuid.NewString(),
				[]byte{byte(i)},
				messaging.ContentTypeMLSMessage,
			)
			if err != nil {
				errs <- err
				return
			}
			results <- res.Envelope.ConversationSeq
		}(i)
	}
	wg.Wait()
	close(errs)
	close(results)
	for err := range errs {
		t.Fatalf("send failed: %v", err)
	}

	seen := map[int64]bool{}
	var max int64
	for seq := range results {
		if seq <= 0 {
			t.Fatalf("invalid seq %d", seq)
		}
		if seen[seq] {
			t.Fatalf("duplicate conversation_seq %d", seq)
		}
		seen[seq] = true
		if seq > max {
			max = seq
		}
	}
	if len(seen) != n {
		t.Fatalf("expected %d unique seqs, got %d", n, len(seen))
	}
	if max != int64(n) {
		t.Fatalf("expected dense seq 1..%d, max=%d", n, max)
	}
}
