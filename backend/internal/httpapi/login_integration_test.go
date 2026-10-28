package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestCompletePasswordlessLogin(t *testing.T) {
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

	if err := db.Ping(ctx); err != nil {
		t.Fatal(err)
	}

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}

	limiter := auth.NewOTPRateLimiter(db)
	issuer, err := auth.NewOTPIssuer(db, secret, limiter)
	if err != nil {
		t.Fatal(err)
	}

	sender := auth.NewMemoryOTPSender()
	requestService, err := auth.NewOTPRequestService(issuer, sender)
	if err != nil {
		t.Fatal(err)
	}

	loginService, err := auth.NewLoginService(db, secret)
	if err != nil {
		t.Fatal(err)
	}

	router := NewRouterWithAuthentication(
		NewAuthHandler(requestService),
		NewVerifyOTPHandler(loginService),
	)

	email := fmt.Sprintf(
		"login-%s@example.com",
		uuid.NewString(),
	)

	t.Cleanup(func() {
		cleanupCtx := context.Background()

		_, _ = db.Exec(cleanupCtx, `
			DELETE FROM sessions
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = db.Exec(cleanupCtx, `
			DELETE FROM devices
			WHERE user_id IN (
				SELECT id FROM users WHERE email_normalized = $1
			)
		`, email)

		_, _ = db.Exec(cleanupCtx,
			"DELETE FROM users WHERE email_normalized = $1",
			email,
		)
		_, _ = db.Exec(cleanupCtx,
			"DELETE FROM email_challenges WHERE email_normalized = $1",
			email,
		)
		_, _ = db.Exec(cleanupCtx,
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
	})

	// 1. Request OTP.
	requestBody, _ := json.Marshal(map[string]string{
		"email": email,
	})

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		bytes.NewReader(requestBody),
	)

	requestRecorder := httptest.NewRecorder()
	router.ServeHTTP(requestRecorder, request)

	if requestRecorder.Code != http.StatusAccepted {
		t.Fatalf(
			"OTP request: expected 202, got %d: %s",
			requestRecorder.Code,
			requestRecorder.Body.String(),
		)
	}

	// 2. Read code from test-only sender.
	messages := sender.Messages()
	if len(messages) != 1 {
		t.Fatalf("expected one OTP message, got %d", len(messages))
	}

	// 3. Verify OTP through HTTP.
	verifyBody, _ := json.Marshal(map[string]string{
		"challenge_id": messages[0].ChallengeID,
		"code":         messages[0].Code,
		"device_name":  "Integration Test Device",
	})

	verifyRequest := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		bytes.NewReader(verifyBody),
	)

	verifyRecorder := httptest.NewRecorder()
	router.ServeHTTP(verifyRecorder, verifyRequest)

	if verifyRecorder.Code != http.StatusOK {
		t.Fatalf(
			"OTP verification: expected 200, got %d: %s",
			verifyRecorder.Code,
			verifyRecorder.Body.String(),
		)
	}

	var result struct {
		UserID    uuid.UUID `json:"user_id"`
		DeviceID  uuid.UUID `json:"device_id"`
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}

	if err := json.Unmarshal(
		verifyRecorder.Body.Bytes(),
		&result,
	); err != nil {
		t.Fatal(err)
	}

	if result.UserID == uuid.Nil ||
		result.DeviceID == uuid.Nil ||
		result.Token == "" {
		t.Fatal("incomplete login response")
	}

	if !result.ExpiresAt.After(time.Now()) {
		t.Fatal("session expiration is not in the future")
	}

	// 4. Verify the session exists and belongs to
	// the returned user and device.
	var storedHash []byte
	var sessionCount int

	err = db.QueryRow(ctx, `
		SELECT token_hash
		FROM sessions
		WHERE user_id = $1
		  AND device_id = $2
		  AND revoked_at IS NULL
	`, result.UserID, result.DeviceID).Scan(&storedHash)

	if err != nil {
		t.Fatal(err)
	}

	err = db.QueryRow(ctx, `
		SELECT COUNT(*)
		FROM sessions
		WHERE user_id = $1
		  AND revoked_at IS NULL
	`, result.UserID).Scan(&sessionCount)

	if err != nil {
		t.Fatal(err)
	}

	if sessionCount != 1 {
		t.Fatalf("expected one active session, got %d", sessionCount)
	}

	// 5. Verify the database stores only the hash.
	expectedHash := auth.HashSessionToken(result.Token)

	if !bytes.Equal(storedHash, expectedHash[:]) {
		t.Fatal("stored session hash does not match token")
	}

	if bytes.Equal(storedHash, []byte(result.Token)) {
		t.Fatal("plaintext session token stored in database")
	}

	// 6. Attempt OTP replay.
	replayRequest := httptest.NewRequest(
		http.MethodPost,
		"/auth/verify-otp",
		bytes.NewReader(verifyBody),
	)

	replayRecorder := httptest.NewRecorder()
	router.ServeHTTP(replayRecorder, replayRequest)

	if replayRecorder.Code != http.StatusUnauthorized {
		t.Fatalf(
			"OTP replay: expected 401, got %d",
			replayRecorder.Code,
		)
	}
}
