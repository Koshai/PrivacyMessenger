package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestRequestOTPHTTPIntegration(t *testing.T) {
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

	secret := []byte("0123456789abcdef0123456789abcdef")

	limiter := auth.NewOTPRateLimiter(db)

	issuer, err := auth.NewOTPIssuer(db, secret, limiter)
	if err != nil {
		t.Fatal(err)
	}

	sender := auth.NewMemoryOTPSender()

	service, err := auth.NewOTPRequestService(
		issuer,
		sender,
	)
	if err != nil {
		t.Fatal(err)
	}

	router := NewRouterWithAuth(NewAuthHandler(service))

	email := fmt.Sprintf(
		"http-%s@example.com",
		uuid.NewString(),
	)

	t.Cleanup(func() {
		_, _ = db.Exec(
			context.Background(),
			"DELETE FROM email_challenges WHERE email_normalized = $1",
			email,
		)
		_, _ = db.Exec(
			context.Background(),
			"DELETE FROM otp_request_limits WHERE email_normalized = $1",
			email,
		)
	})

	body := fmt.Sprintf(`{"email":%q}`, email)

	request := httptest.NewRequest(
		http.MethodPost,
		"/auth/request-otp",
		strings.NewReader(body),
	)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusAccepted {
		t.Fatalf(
			"expected 202, got %d: %s",
			recorder.Code,
			recorder.Body.String(),
		)
	}

	var response struct {
		Message string `json:"message"`
	}

	if err := json.Unmarshal(
		recorder.Body.Bytes(),
		&response,
	); err != nil {
		t.Fatal(err)
	}

	if response.Message == "" {
		t.Fatal("missing response message")
	}

	messages := sender.Messages()
	if len(messages) != 1 {
		t.Fatalf(
			"expected one delivered message, got %d",
			len(messages),
		)
	}

	challengeID, err := uuid.Parse(messages[0].ChallengeID)
	if err != nil {
		t.Fatal(err)
	}

	var codeHash []byte
	err = db.QueryRow(ctx, `
		SELECT code_hash
		FROM email_challenges
		WHERE id = $1
	`, challengeID).Scan(&codeHash)

	if err != nil {
		t.Fatal(err)
	}

	if !auth.VerifyOTPHash(
		secret,
		challengeID.String(),
		messages[0].Code,
		codeHash,
	) {
		t.Fatal("delivered OTP does not match database hash")
	}
}
