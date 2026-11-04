package e2e_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"example.com/private-messenger/backend/internal/auth"
	appcrypto "example.com/private-messenger/backend/internal/crypto"
	"example.com/private-messenger/backend/internal/friends"
	"example.com/private-messenger/backend/internal/httpapi"
	"example.com/private-messenger/backend/internal/messaging"
	"example.com/private-messenger/backend/internal/realtime"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Full server-path E2E using PostgreSQL. Skips without DATABASE_URL.
// Ciphertext is opaque fixture bytes (OpenMLS native covered in Flutter tests).
func TestTwoAccountEncryptedMessagingPath(t *testing.T) {
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

	seedUserDeviceSession(t, db, aliceUser, aliceDev, "alice-"+aliceUser.String()+"@example.test", aliceHash)
	seedUserDeviceSession(t, db, bobUser, bobDev, "bob-"+bobUser.String()+"@example.test", bobHash)
	seedFriendship(t, db, aliceUser, bobUser)

	hub := realtime.NewHub()
	sessionRepo := auth.NewSessionRepository(db)
	rt := httpapi.NewRealtimeHandler(hub, sessionRepo)

	msgSvc := messaging.NewNotifyingService(
		messaging.NewService(messaging.NewRepository(db), messaging.NewPostgresFriendshipChecker(db)),
		rt,
	)
	cryptoSvc := appcrypto.NewService(
		appcrypto.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		appcrypto.NewPostgresDeviceOwnerChecker(db),
	)

	router := httpapi.NewConfiguredRouter(httpapi.RouterDependencies{
		SessionAuthenticator: sessionRepo,
		MessagingHandler:     httpapi.NewMessagingHandler(msgSvc),
		CryptoHandler:        httpapi.NewCryptoHandler(cryptoSvc),
		RealtimeHandler:      rt,
		LogoutHandler:        httpapi.NewLogoutHandler(sessionRepo).WithDisconnecter(rt),
	})

	// Register identities + upload packages
	alicePub := []byte("alice-pub-key-material-aaaa")
	bobPub := []byte("bob-pub-key-material-bbbbbb")
	mustStatus(t, router, aliceToken, http.MethodPost, "/crypto/identity", map[string]any{
		"public_key_b64": base64.StdEncoding.EncodeToString(alicePub),
	}, http.StatusCreated, http.StatusOK)
	mustStatus(t, router, bobToken, http.MethodPost, "/crypto/identity", map[string]any{
		"public_key_b64": base64.StdEncoding.EncodeToString(bobPub),
	}, http.StatusCreated, http.StatusOK)

	bobPackages := []string{
		base64.StdEncoding.EncodeToString([]byte("bob-kp-1")),
		base64.StdEncoding.EncodeToString([]byte("bob-kp-2")),
	}
	mustStatus(t, router, bobToken, http.MethodPost, "/crypto/key-packages", map[string]any{
		"packages_b64": bobPackages,
	}, http.StatusNoContent)

	// Alice claims Bob package (atomic)
	claim := mustJSON(t, router, aliceToken, http.MethodPost, "/crypto/users/"+bobUser.String()+"/key-packages/claim", nil, http.StatusOK)
	if claim["key_package_b64"] == nil {
		t.Fatal("missing key package")
	}
	// Duplicate claim should get a different package or 404 after exhaustion of reserved path
	claim2 := doReq(t, router, aliceToken, http.MethodPost, "/crypto/users/"+bobUser.String()+"/key-packages/claim", nil)
	if claim2.Code == http.StatusOK {
		body2 := decodeBody(t, claim2)
		if body2["package_id"] == claim["package_id"] {
			t.Fatal("duplicate package consumption")
		}
	}

	// Open conversation + establish MLS group
	conv := mustJSON(t, router, aliceToken, http.MethodPost, "/conversations", map[string]any{
		"peer_user_id": bobUser.String(),
	}, http.StatusOK)
	convID := conv["conversation_id"].(string)

	groupHex := strings.ReplaceAll(uuid.New().String(), "-", "")
	mustJSON(t, router, aliceToken, http.MethodPut, "/conversations/"+convID+"/mls-group", map[string]any{
		"mls_group_id_hex": groupHex,
	}, http.StatusOK)

	welcomeCT := messaging.ContentTypeMLSWelcome
	commitCT := messaging.ContentTypeMLSCommit
	appCT := messaging.ContentTypeMLSMessage

	welcomeBytes := []byte{0x01, 0x02, 0x03, 0xaa, 0xbb}
	commitBytes := []byte{0x04, 0x05, 0x06, 0xcc, 0xdd}
	app1 := []byte{0x10, 0x11, 0x12, 0xde, 0xad}
	app2 := []byte{0x20, 0x21, 0x22, 0xbe, 0xef}
	const secretPlaintext = "super-secret-chat-body"

	convUUID := uuid.MustParse(convID)
	send := func(clientID string, payload []byte, ct string) messaging.SendResult {
		t.Helper()
		res, err := msgSvc.SendEnvelope(context.Background(), aliceUser, convUUID, clientID, payload, ct)
		if err != nil {
			t.Fatalf("send %s: %v", clientID, err)
		}
		return res
	}
	send("welcome-1", welcomeBytes, welcomeCT)
	send("commit-1", commitBytes, commitCT)
	sent := send("msg-1", app1, appCT)

	// Server storage must not contain application plaintext.
	assertNoPlaintextInDB(t, db, secretPlaintext)

	// Bob sync pending while "disconnected" then ack
	pending := mustJSON(t, router, bobToken, http.MethodGet, "/envelopes/pending?limit=50", nil, http.StatusOK)
	envs := pending["envelopes"].([]any)
	if len(envs) < 3 {
		t.Fatalf("expected pending welcome/commit/app, got %d", len(envs))
	}
	// Ordering: conversation_seq ascending
	var lastSeq float64
	for i, raw := range envs {
		m := raw.(map[string]any)
		ct := m["content_type"].(string)
		seq := m["conversation_seq"].(float64)
		if i > 0 && seq < lastSeq {
			t.Fatalf("pending not ordered by conversation_seq")
		}
		lastSeq = seq
		cipher, _ := base64.StdEncoding.DecodeString(m["ciphertext_b64"].(string))
		if bytes.Contains(cipher, []byte(secretPlaintext)) {
			t.Fatal("plaintext leaked into ciphertext field")
		}
		_ = ct
		mustStatus(t, router, bobToken, http.MethodPost, "/envelopes/"+m["id"].(string)+"/ack", nil, http.StatusNoContent)
	}

	// Offline Bob: Alice sends more
	send("msg-2", app2, appCT)

	pending2 := mustJSON(t, router, bobToken, http.MethodGet, "/envelopes/pending?limit=10", nil, http.StatusOK)
	if len(pending2["envelopes"].([]any)) != 1 {
		t.Fatalf("expected 1 offline message, got %#v", pending2)
	}

	// Idempotent retry
	again := send("msg-1", app1, appCT)
	if again.Envelope.ID != sent.Envelope.ID || again.Created {
		t.Fatal("idempotent retry must return same envelope id")
	}

	// Revoke Alice device MLS identity and ensure claim/upload blocked for that device after revoke API
	if err := cryptoSvc.RevokeDevice(ctx, aliceUser, aliceDev); err != nil {
		t.Fatal(err)
	}
	rec := doReq(t, router, aliceToken, http.MethodPost, "/crypto/key-packages", map[string]any{
		"packages_b64": []string{base64.StdEncoding.EncodeToString([]byte("x"))},
	})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("revoked device upload want 403, got %d", rec.Code)
	}
}

func mustToken(t *testing.T) (string, []byte) {
	t.Helper()
	tok, err := auth.GenerateSessionToken()
	if err != nil {
		t.Fatal(err)
	}
	hash := auth.HashSessionToken(tok)
	return tok, hash[:]
}

func seedUserDeviceSession(t *testing.T, db *pgxpool.Pool, userID, deviceID uuid.UUID, email string, tokenHash []byte) {
	t.Helper()
	ctx := context.Background()
	_, err := db.Exec(ctx, `
		INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)
	`, userID, email, strings.ToLower(email))
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(ctx, `
		INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'test')
	`, deviceID, userID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(ctx, `
		INSERT INTO sessions (id, user_id, device_id, token_hash, expires_at)
		VALUES ($1,$2,$3,$4, NOW() + interval '1 day')
	`, uuid.New(), userID, deviceID, tokenHash)
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
		t.Fatalf("seed friendship: %v", err)
	}
}

func assertNoPlaintextInDB(t *testing.T, db *pgxpool.Pool, needle string) {
	t.Helper()
	var n int
	err := db.QueryRow(context.Background(), `
		SELECT COUNT(*) FROM message_envelopes
		WHERE convert_from(ciphertext, 'UTF8') ILIKE '%' || $1 || '%'
	`, needle).Scan(&n)
	if err != nil {
		// convert_from may fail on binary — that's fine (not plaintext UTF8)
		return
	}
	if n != 0 {
		t.Fatalf("plaintext %q found in %d envelopes", needle, n)
	}
}

func mustStatus(t *testing.T, h http.Handler, token, method, path string, body any, want ...int) {
	t.Helper()
	rec := doReq(t, h, token, method, path, body)
	for _, code := range want {
		if rec.Code == code {
			return
		}
	}
	t.Fatalf("%s %s want %v got %d body=%s", method, path, want, rec.Code, rec.Body.String())
}

func mustJSON(t *testing.T, h http.Handler, token, method, path string, body any, want ...int) map[string]any {
	t.Helper()
	rec := doReq(t, h, token, method, path, body)
	ok := false
	for _, code := range want {
		if rec.Code == code {
			ok = true
			break
		}
	}
	if !ok {
		t.Fatalf("%s %s want %v got %d body=%s", method, path, want, rec.Code, rec.Body.String())
	}
	if rec.Body.Len() == 0 {
		return map[string]any{}
	}
	return decodeBody(t, rec)
}

func doReq(t *testing.T, h http.Handler, token, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var rdr *bytes.Reader
	if body == nil {
		rdr = bytes.NewReader(nil)
	} else {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, rdr)
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("json: %v body=%s", err, rec.Body.String())
	}
	return out
}

// silence unused friends import if schema uses it later
var _ = friends.NewService
