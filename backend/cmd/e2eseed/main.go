// Command e2eseed inserts isolated Alice/Bob fixtures for the live Flutter
// OpenMLS ↔ API harness. Prints one JSON object to stdout (no secrets to logs
// beyond the fixture file the caller redirects).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"example.com/private-messenger/backend/internal/auth"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		fatal("DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	db, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		fatal(err.Error())
	}
	defer db.Close()

	aliceUser := uuid.New()
	bobUser := uuid.New()
	aliceDev := uuid.New()
	bobDev := uuid.New()
	aliceToken, err := auth.GenerateSessionToken()
	if err != nil {
		fatal(err.Error())
	}
	bobToken, err := auth.GenerateSessionToken()
	if err != nil {
		fatal(err.Error())
	}
	aliceHash := auth.HashSessionToken(aliceToken)
	bobHash := auth.HashSessionToken(bobToken)

	aliceEmail := fmt.Sprintf("alice-%s@example.test", aliceUser.String())
	bobEmail := fmt.Sprintf("bob-%s@example.test", bobUser.String())

	mustExec(ctx, db, `INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)`,
		aliceUser, aliceEmail, strings.ToLower(aliceEmail))
	mustExec(ctx, db, `INSERT INTO users (id, email, email_normalized) VALUES ($1,$2,$3)`,
		bobUser, bobEmail, strings.ToLower(bobEmail))
	mustExec(ctx, db, `INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'alice-live')`,
		aliceDev, aliceUser)
	mustExec(ctx, db, `INSERT INTO devices (id, user_id, device_name) VALUES ($1,$2,'bob-live')`,
		bobDev, bobUser)
	mustExec(ctx, db, `
		INSERT INTO sessions (id, user_id, device_id, token_hash, expires_at)
		VALUES ($1,$2,$3,$4, NOW() + interval '1 day')`,
		uuid.New(), aliceUser, aliceDev, aliceHash[:])
	mustExec(ctx, db, `
		INSERT INTO sessions (id, user_id, device_id, token_hash, expires_at)
		VALUES ($1,$2,$3,$4, NOW() + interval '1 day')`,
		uuid.New(), bobUser, bobDev, bobHash[:])
	mustExec(ctx, db, `
		INSERT INTO friendships (id, requester_id, addressee_id, status, created_at, updated_at)
		VALUES ($1,$2,$3,'ACCEPTED',NOW(),NOW())`,
		uuid.New(), aliceUser, bobUser)

	out := map[string]any{
		"alice": map[string]string{
			"user_id":   aliceUser.String(),
			"device_id": aliceDev.String(),
			"token":     aliceToken,
			"email":     aliceEmail,
		},
		"bob": map[string]string{
			"user_id":   bobUser.String(),
			"device_id": bobDev.String(),
			"token":     bobToken,
			"email":     bobEmail,
		},
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		fatal(err.Error())
	}
}

func mustExec(ctx context.Context, db *pgxpool.Pool, sql string, args ...any) {
	if _, err := db.Exec(ctx, sql, args...); err != nil {
		fatal(err.Error())
	}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
