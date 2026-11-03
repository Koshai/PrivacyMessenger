package friends

import (
	"context"
	"os"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/database"

	"github.com/google/uuid"
)

func setupFriendsIntegration(t *testing.T) (*Repository, context.Context) {
	t.Helper()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set; skipping PostgreSQL integration test")
	}

	ctx := context.Background()
	pool, err := database.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	return NewRepository(pool), ctx
}

func insertTestUser(t *testing.T, repo *Repository, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	_, err := repo.db.Exec(context.Background(), `
		INSERT INTO users (id, email, email_normalized)
		VALUES ($1, $2, $2)
	`, id, email)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = repo.db.Exec(context.Background(), `DELETE FROM friendships WHERE requester_id = $1 OR addressee_id = $1`, id)
		_, _ = repo.db.Exec(context.Background(), `DELETE FROM user_blocks WHERE blocker_id = $1 OR blocked_id = $1`, id)
		_, _ = repo.db.Exec(context.Background(), `DELETE FROM friend_request_limits WHERE requester_id = $1`, id)
		_, _ = repo.db.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, id)
	})
	return id
}

func TestRepositoryEnforcesAcceptedPairConstraint(t *testing.T) {
	repo, ctx := setupFriendsIntegration(t)
	alice := insertTestUser(t, repo, "alice-friends-"+uuid.NewString()+"@example.com")
	bob := insertTestUser(t, repo, "bob-friends-"+uuid.NewString()+"@example.com")

	first, err := repo.CreatePending(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.UpdateStatus(ctx, first.ID, StatusAccepted); err != nil {
		t.Fatal(err)
	}

	second, err := repo.CreatePending(ctx, bob, alice)
	if err != nil {
		t.Fatal(err)
	}
	err = repo.UpdateStatus(ctx, second.ID, StatusAccepted)
	if err == nil {
		t.Fatal("expected unique accepted-pair constraint to reject second acceptance")
	}
}

func TestRepositoryPendingUniqueConstraint(t *testing.T) {
	repo, ctx := setupFriendsIntegration(t)
	alice := insertTestUser(t, repo, "alice-pending-"+uuid.NewString()+"@example.com")
	bob := insertTestUser(t, repo, "bob-pending-"+uuid.NewString()+"@example.com")

	if _, err := repo.CreatePending(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.CreatePending(ctx, alice, bob); err == nil {
		t.Fatal("expected duplicate pending insert to fail")
	}
}

func TestServiceIntegrationRequestAcceptRemove(t *testing.T) {
	repo, ctx := setupFriendsIntegration(t)
	service := NewService(repo.db)

	aliceEmail := "alice-svc-" + uuid.NewString() + "@example.com"
	bobEmail := "bob-svc-" + uuid.NewString() + "@example.com"
	alice := insertTestUser(t, repo, aliceEmail)
	bob := insertTestUser(t, repo, bobEmail)

	if err := service.RequestByEmail(ctx, alice, bobEmail); err != nil {
		t.Fatal(err)
	}

	incoming, err := service.ListIncoming(ctx, bob)
	if err != nil || len(incoming) != 1 {
		t.Fatalf("expected one incoming request, got %#v (%v)", incoming, err)
	}

	if err := service.Accept(ctx, bob, incoming[0].ID); err != nil {
		t.Fatal(err)
	}

	count, err := service.FriendCount(ctx, alice)
	if err != nil || count != 1 {
		t.Fatalf("expected count 1, got %d (%v)", count, err)
	}

	if err := service.RemoveFriend(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}

	count, err = service.FriendCount(ctx, alice)
	if err != nil || count != 0 {
		t.Fatalf("expected count 0 after remove, got %d (%v)", count, err)
	}
}

func TestServiceIntegrationBlockBehavior(t *testing.T) {
	repo, ctx := setupFriendsIntegration(t)
	service := NewService(repo.db)

	aliceEmail := "alice-block-" + uuid.NewString() + "@example.com"
	bobEmail := "bob-block-" + uuid.NewString() + "@example.com"
	alice := insertTestUser(t, repo, aliceEmail)
	bob := insertTestUser(t, repo, bobEmail)

	if err := service.RequestByEmail(ctx, alice, bobEmail); err != nil {
		t.Fatal(err)
	}
	incoming, err := service.ListIncoming(ctx, bob)
	if err != nil || len(incoming) != 1 {
		t.Fatal(err)
	}
	if err := service.Accept(ctx, bob, incoming[0].ID); err != nil {
		t.Fatal(err)
	}

	if err := service.BlockByUserID(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}

	// Silent success — no new pending friendship.
	if err := service.RequestByEmail(ctx, bob, aliceEmail); err != nil {
		t.Fatal(err)
	}
	outgoing, err := service.ListOutgoing(ctx, bob)
	if err != nil {
		t.Fatal(err)
	}
	if len(outgoing) != 0 {
		t.Fatalf("expected no outgoing request after block, got %#v", outgoing)
	}

	blocks, err := service.ListBlocked(ctx, alice)
	if err != nil || len(blocks) != 1 {
		t.Fatalf("expected one block, got %#v (%v)", blocks, err)
	}

	if err := service.Unblock(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}

	_ = time.Now()
}
