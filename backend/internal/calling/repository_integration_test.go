package calling_test

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"

	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresCallLifecycleD11(t *testing.T) {
	db := mustDB(t)
	ctx := context.Background()
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

	res, err := svc.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, "pg-d11-1")
	if err != nil || !res.Created {
		t.Fatalf("initiate: %#v %v", res, err)
	}
	if _, err := svc.Accept(ctx, bob, bobDev, res.Session.ID); err != nil {
		t.Fatal(err)
	}
	otherDev := uuid.New()
	seedDeviceOnly(t, db, bob, otherDev)
	if _, err := svc.Accept(ctx, bob, otherDev, res.Session.ID); err != calling.ErrDeviceConflict {
		t.Fatalf("want device conflict, got %v", err)
	}
	if _, err := svc.SetOffer(ctx, alice, res.Session.ID, "offer-sdp"); err != nil {
		t.Fatal(err)
	}
	ans, err := svc.SetAnswer(ctx, bob, res.Session.ID, "answer-sdp")
	if err != nil {
		t.Fatal(err)
	}
	if ans.State != calling.StateAccepted {
		t.Fatalf("answer must not set connected, got %s", ans.State)
	}
	conn, err := svc.MarkConnected(ctx, bob, res.Session.ID)
	if err != nil || conn.State != calling.StateConnected {
		t.Fatalf("connected: %#v %v", conn, err)
	}
	if _, _, err := svc.AddICE(ctx, alice, res.Session.ID, "cand:1", "ice-1", nil, nil); err != nil {
		t.Fatal(err)
	}
	ended, err := svc.HangUp(ctx, bob, res.Session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if ended.SDPOffer != nil || ended.SDPAnswer != nil {
		t.Fatal("sdp must clear atomically")
	}
	left, err := svc.ListICE(ctx, alice, res.Session.ID, 0, 10)
	if err != nil || len(left) != 0 {
		t.Fatalf("ice leftover %#v", left)
	}
}

func TestPostgresSimultaneousInitiate(t *testing.T) {
	db := mustDB(t)
	ctx := context.Background()
	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	seedUserDevice(t, db, alice, aliceDev, "sim-a-"+alice.String()+"@example.test")
	seedUserDevice(t, db, bob, bobDev, "sim-b-"+bob.String()+"@example.test")
	seedFriendship(t, db, alice, bob)
	svc := calling.NewService(
		calling.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		calling.NewPostgresBlockChecker(db),
	)

	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := svc.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, uuid.NewString())
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	ok, busy := 0, 0
	for err := range errs {
		switch err {
		case nil:
			ok++
		case calling.ErrBusy:
			busy++
		default:
			t.Fatalf("unexpected %v", err)
		}
	}
	if ok != 1 || busy != 15 {
		t.Fatalf("want 1 success 15 busy, got %d/%d", ok, busy)
	}
	_ = bobDev
}

func TestPostgresBlockedPrivacy(t *testing.T) {
	db := mustDB(t)
	ctx := context.Background()
	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	seedUserDevice(t, db, alice, aliceDev, "blk-a-"+alice.String()+"@example.test")
	seedUserDevice(t, db, bob, bobDev, "blk-b-"+bob.String()+"@example.test")
	seedFriendship(t, db, alice, bob)
	_, err := db.Exec(ctx, `INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1,$2)`, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	svc := calling.NewService(
		calling.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		calling.NewPostgresBlockChecker(db),
	)
	_, err = svc.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, "blocked")
	if err != calling.ErrNotAvailable {
		t.Fatalf("want not available, got %v", err)
	}
}

func mustDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not configured")
	}
	db, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	return db
}

func seedUserDevice(t *testing.T, db *pgxpool.Pool, userID, deviceID uuid.UUID, email string) {
	t.Helper()
	ctx := context.Background()
	_, err := db.Exec(ctx, `INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)`,
		userID, email, strings.ToLower(email))
	if err != nil {
		t.Fatal(err)
	}
	seedDeviceOnly(t, db, userID, deviceID)
}

func seedDeviceOnly(t *testing.T, db *pgxpool.Pool, userID, deviceID uuid.UUID) {
	t.Helper()
	_, err := db.Exec(context.Background(), `INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'call-test')`, deviceID, userID)
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
