package calling_test

import (
	"context"
	"os"
	"strings"
	"testing"

	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresCallLifecycle(t *testing.T) {
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

	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	seedUserDevice(t, db, alice, aliceDev, "call-a-"+alice.String()+"@example.test")
	seedUserDevice(t, db, bob, bobDev, "call-b-"+bob.String()+"@example.test")
	seedFriendship(t, db, alice, bob)

	svc := calling.NewService(
		calling.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		calling.NewPostgresBlockChecker(db),
	)

	res, err := svc.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, "pg-1")
	if err != nil || !res.Created {
		t.Fatalf("initiate: %#v %v", res, err)
	}
	accepted, err := svc.Accept(ctx, bob, bobDev, res.Session.ID)
	if err != nil || accepted.State != calling.StateAccepted {
		t.Fatalf("accept: %#v %v", accepted, err)
	}
	if _, err := svc.SetOffer(ctx, alice, res.Session.ID, "offer-sdp"); err != nil {
		t.Fatal(err)
	}
	connected, err := svc.SetAnswer(ctx, bob, res.Session.ID, "answer-sdp")
	if err != nil || connected.State != calling.StateConnected {
		t.Fatalf("answer: %#v %v", connected, err)
	}
	ice, created, err := svc.AddICE(ctx, alice, res.Session.ID, "cand:1", "ice-pg-1", nil, nil)
	if err != nil || !created || ice.Seq < 1 {
		t.Fatalf("ice: %#v %v", ice, err)
	}
	listed, err := svc.ListICE(ctx, bob, res.Session.ID, 0, 10)
	if err != nil || len(listed) != 1 {
		t.Fatalf("list ice: %#v %v", listed, err)
	}
	ended, err := svc.HangUp(ctx, bob, res.Session.ID)
	if err != nil || ended.State != calling.StateEnded {
		t.Fatalf("hangup: %#v %v", ended, err)
	}
	got, err := svc.Get(ctx, alice, res.Session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.SDPOffer != nil || got.SDPAnswer != nil {
		t.Fatal("sdp must be cleared after hangup")
	}
	left, err := svc.ListICE(ctx, alice, res.Session.ID, 0, 10)
	if err != nil || len(left) != 0 {
		t.Fatalf("ice must be deleted, got %#v", left)
	}
}

func seedUserDevice(t *testing.T, db *pgxpool.Pool, userID, deviceID uuid.UUID, email string) {
	t.Helper()
	ctx := context.Background()
	_, err := db.Exec(ctx, `INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)`,
		userID, email, strings.ToLower(email))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(ctx, `INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'call-test')`, deviceID, userID)
	if err != nil {
		t.Fatal(err)
	}
}

func seedFriendship(t *testing.T, db *pgxpool.Pool, a, b uuid.UUID) {
	t.Helper()
	_, err := db.Exec(context.Background(), `
		INSERT INTO friendships (id, requester_id, addressee_id, status, created_at, updated_at)
		VALUES ($1,$2,$3,'ACCEPTED',NOW(),NOW())
	`, uuid.New(), a, b)
	if err != nil {
		t.Fatal(err)
	}
}

func TestPostgresBlockedCannotCall(t *testing.T) {
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

	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	seedUserDevice(t, db, alice, aliceDev, "blk-a-"+alice.String()+"@example.test")
	seedUserDevice(t, db, bob, bobDev, "blk-b-"+bob.String()+"@example.test")
	seedFriendship(t, db, alice, bob)
	_, err = db.Exec(ctx, `INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1,$2)`, alice, bob)
	if err != nil {
		t.Fatal(err)
	}

	svc := calling.NewService(
		calling.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		calling.NewPostgresBlockChecker(db),
	)
	_, err = svc.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, "blocked-1")
	if err != calling.ErrBlocked {
		t.Fatalf("want blocked, got %v", err)
	}
	_ = bobDev
}
