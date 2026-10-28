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

func TestCompleteLoginLogoutLifecycle(t *testing.T) {
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

	requestService, err := auth.NewOTPRequestService(
		issuer,
		sender,
	)
	if err != nil {
		t.Fatal(err)
	}

	loginService, err := auth.NewLoginService(db, secret)
	if err != nil {
		t.Fatal(err)
	}

	sessionRepository := auth.NewSessionRepository(db)
	logoutHandler := NewLogoutHandler(sessionRepository)

	router := NewRouterWithLogout(
		NewAuthHandler(requestService),
		NewVerifyOTPHandler(loginService),
		sessionRepository,
		logoutHandler,
	)

	email := fmt.Sprintf(
		"logout-%s@example.com",
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

		_, _ = db.Exec(
			cleanupCtx,
			"DELETE FROM users WHERE email_normalized = $1",
			email,
		)

		_, _ = db.Exec(
			cleanupCtx,
			"DELETE FROM email_challenges WHERE email_normalized = $1",
			email,
		)

		_, _ = db.Exec(
			cleanupCtx,
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
	})

	// Step 1: Request OTP.
	requestBody, _ := json.Marshal(map[string]string{
		"email": email,
	})

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		bytes.NewReader(requestBody),
	)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusAccepted {
		t.Fatalf(
			"request OTP: expected 202, got %d: %s",
			recorder.Code,
			recorder.Body.String(),
		)
	}

	messages := sender.Messages()
	if len(messages) != 1 {
		t.Fatalf(
			"expected one OTP message, got %d",
			len(messages),
		)
	}

	// Step 2: Verify OTP and obtain session token.
	verifyBody, _ := json.Marshal(map[string]string{
		"challenge_id": messages[0].ChallengeID,
		"code":         messages[0].Code,
		"device_name":  "Logout Integration Device",
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
			"verify OTP: expected 200, got %d: %s",
			verifyRecorder.Code,
			verifyRecorder.Body.String(),
		)
	}

	var login struct {
		UserID   uuid.UUID `json:"user_id"`
		DeviceID uuid.UUID `json:"device_id"`
		Token    string    `json:"token"`
	}

	if err := json.Unmarshal(
		verifyRecorder.Body.Bytes(),
		&login,
	); err != nil {
		t.Fatal(err)
	}

	if login.Token == "" {
		t.Fatal("login returned empty token")
	}

	// Helper for authenticated requests.
	sendAuthenticated := func(
		method string,
		path string,
	) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		req.Header.Set(
			"Authorization",
			"Bearer "+login.Token,
		)

		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		return rec
	}

	// Step 3: Confirm session works before logout.
	beforeLogout := sendAuthenticated(
		http.MethodGet,
		"/auth/me",
	)

	if beforeLogout.Code != http.StatusOK {
		t.Fatalf(
			"before logout: expected 200, got %d",
			beforeLogout.Code,
		)
	}

	// Step 4: Logout.
	logoutResponse := sendAuthenticated(
		http.MethodPost,
		"/auth/logout",
	)

	if logoutResponse.Code != http.StatusNoContent {
		t.Fatalf(
			"logout: expected 204, got %d: %s",
			logoutResponse.Code,
			logoutResponse.Body.String(),
		)
	}

	// Step 5: Confirm session no longer works.
	afterLogout := sendAuthenticated(
		http.MethodGet,
		"/auth/me",
	)

	if afterLogout.Code != http.StatusUnauthorized {
		t.Fatalf(
			"after logout: expected 401, got %d",
			afterLogout.Code,
		)
	}

	// Step 6: Confirm revocation was persisted.
	var revokedAt *time.Time

	err = db.QueryRow(ctx, `
		SELECT revoked_at
		FROM sessions
		WHERE user_id = $1
		  AND device_id = $2
	`, login.UserID, login.DeviceID).Scan(&revokedAt)

	if err != nil {
		t.Fatal(err)
	}

	if revokedAt == nil {
		t.Fatal("session revocation was not persisted")
	}

	// Step 7: A second logout must not succeed.
	secondLogout := sendAuthenticated(
		http.MethodPost,
		"/auth/logout",
	)

	if secondLogout.Code != http.StatusUnauthorized {
		t.Fatalf(
			"second logout: expected 401, got %d",
			secondLogout.Code,
		)
	}
}
