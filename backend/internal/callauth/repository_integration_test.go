package callauth_test

import (
	"context"
	"crypto/ed25519"
	"os"
	"strings"
	"testing"

	"example.com/private-messenger/backend/internal/callauth"
	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/messaging"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresCallAuthHello(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not configured")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)

	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	seed(t, db, alice, aliceDev, "d4a-"+alice.String()+"@example.test")
	seed(t, db, bob, bobDev, "d4b-"+bob.String()+"@example.test")
	if _, err := db.Exec(ctx, `INSERT INTO friendships (id, requester_id, addressee_id, status, created_at, updated_at) VALUES ($1,$2,$3,'ACCEPTED',NOW(),NOW())`, uuid.New(), alice, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO device_mls_identities (device_id, user_id, public_identity_key, fingerprint_hex) VALUES ($1,$2,$3,$4)`, aliceDev, alice, []byte("mls-alice-key"), strings.Repeat("ab", 32)); err != nil {
		t.Fatal(err)
	}

	calls := calling.NewService(calling.NewRepository(db), messaging.NewPostgresFriendshipChecker(db), calling.NewPostgresBlockChecker(db))
	created, err := calls.Initiate(ctx, alice, aliceDev, bob, calling.MediaAudio, "d4-"+alice.String())
	if err != nil {
		t.Fatal(err)
	}
	auth := callauth.NewService(callauth.NewRepository(db), callauth.CallingBridge{Get: calls.Get}, callauth.NewPostgresRevocation(db))
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.RegisterKey(ctx, alice, aliceDev, pub); err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	mls := make([]byte, 32)
	msg, err := (callauth.Hello{CallID: created.Session.ID, UserID: alice, DeviceID: aliceDev, Role: callauth.RoleCaller, Nonce: nonce, CallKey: pub, MLS: mls}).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, msg)
	if _, err := auth.Submit(ctx, callauth.SubmitInput{
		CallID: created.Session.ID, ActorUser: alice, ActorDevice: aliceDev, Kind: callauth.KindHello,
		ClientAuthID: "pg-" + alice.String(), Nonce: nonce, CallKey: pub, MLS: mls, Signature: sig,
	}); err != nil {
		t.Fatal(err)
	}
	if err := auth.Purge(ctx, created.Session.ID); err != nil {
		t.Fatal(err)
	}
}

func seed(t *testing.T, db *pgxpool.Pool, user, device uuid.UUID, email string) {
	t.Helper()
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)`, user, email, strings.ToLower(email)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'d4')`, device, user); err != nil {
		t.Fatal(err)
	}
}
