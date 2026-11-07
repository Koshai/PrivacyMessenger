package messaging

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"
)

func TestConcurrentIdenticalClientMessageIDReplay(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)

	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	const n = 32
	var wg sync.WaitGroup
	errs := make(chan error, n)
	ids := make(chan uuid.UUID, n)
	created := make(chan bool, n)
	payload := []byte{0x11, 0x22, 0x33}

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := service.SendEnvelope(
				context.Background(),
				alice,
				conversation.ID,
				"same-client-id",
				append([]byte(nil), payload...),
				"application/opaque",
			)
			if err != nil {
				errs <- err
				return
			}
			ids <- res.Envelope.ID
			created <- res.Created
			if !bytesEqual(res.Envelope.Ciphertext, payload) {
				errs <- errors.New("replay changed ciphertext")
			}
		}()
	}
	wg.Wait()
	close(errs)
	close(ids)
	close(created)

	for err := range errs {
		t.Fatalf("unexpected error: %v", err)
	}

	var first uuid.UUID
	var createdCount int
	for id := range ids {
		if first == uuid.Nil {
			first = id
		} else if id != first {
			t.Fatalf("idempotent replay returned different envelope ids")
		}
	}
	for c := range created {
		if c {
			createdCount++
		}
	}
	if createdCount != 1 {
		t.Fatalf("expected exactly one created insert, got %d", createdCount)
	}
}

func TestConcurrentConflictingClientMessageIDRejected(t *testing.T) {
	alice, bob := uuid.New(), uuid.New()
	store := newMemoryStore()
	friends := &memoryFriends{pairs: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	service := NewService(store, friends)

	conversation, err := service.OpenConversation(context.Background(), alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	first, err := service.SendEnvelope(
		context.Background(), alice, conversation.ID, "conflict-id", []byte{0x01}, "application/opaque",
	)
	if err != nil || !first.Created {
		t.Fatalf("seed send failed: %#v %v", first, err)
	}

	const n = 24
	var wg sync.WaitGroup
	var conflicts atomic.Int64
	var other atomic.Int64
	errs := make(chan error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := service.SendEnvelope(
				context.Background(),
				alice,
				conversation.ID,
				"conflict-id",
				[]byte{byte(0xA0 + i)},
				"application/opaque",
			)
			if errors.Is(err, ErrClientMessageIDConflict) {
				conflicts.Add(1)
				return
			}
			if err != nil {
				errs <- err
				return
			}
			other.Add(1)
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("unexpected error: %v", err)
	}
	if conflicts.Load() != n {
		t.Fatalf("expected %d conflicts, got %d (non-conflict=%d)", n, conflicts.Load(), other.Load())
	}

	// Original envelope content must remain unchanged.
	second, err := service.SendEnvelope(
		context.Background(), alice, conversation.ID, "conflict-id", []byte{0x01}, "application/opaque",
	)
	if err != nil || second.Created {
		t.Fatalf("identical replay after conflicts failed: %#v %v", second, err)
	}
	if second.Envelope.ID != first.Envelope.ID {
		t.Fatal("identical replay must return original envelope id")
	}
	if !bytesEqual(second.Envelope.Ciphertext, []byte{0x01}) {
		t.Fatal("identical replay must preserve original ciphertext")
	}
}
