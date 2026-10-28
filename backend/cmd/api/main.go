package main

import (
	"context"
	"encoding/base64"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/config"
	"example.com/private-messenger/backend/internal/httpapi"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	secretEncoded := os.Getenv("OTP_HMAC_SECRET")
	secret, err := base64.StdEncoding.DecodeString(secretEncoded)
	if err != nil || len(secret) < 32 {
		log.Fatal("OTP_HMAC_SECRET must be base64-encoded and at least 32 bytes")
	}

	db, err := pgxpool.New(
		context.Background(),
		databaseURL,
	)
	if err != nil {
		log.Fatalf("Database configuration failed: %v", err)
	}
	defer db.Close()

	startupCtx, cancelStartup := context.WithTimeout(
		context.Background(),
		10*time.Second,
	)
	defer cancelStartup()

	if err := db.Ping(startupCtx); err != nil {
		log.Fatalf("Database connection failed: %v", err)
	}

	limiter := auth.NewOTPRateLimiter(db)

	issuer, err := auth.NewOTPIssuer(db, secret, limiter)
	if err != nil {
		log.Fatal(err)
	}

	// Local development only. No actual emails are sent.
	// Replace with a production sender before deployment.
	sender := auth.NewMemoryOTPSender()

	requestService, err := auth.NewOTPRequestService(
		issuer,
		sender,
	)
	if err != nil {
		log.Fatal(err)
	}

	authHandler := httpapi.NewAuthHandler(requestService)

	loginService, err := auth.NewLoginService(db, secret)
	if err != nil {
		log.Fatal(err)
	}

	verifyHandler := httpapi.NewVerifyOTPHandler(loginService)

	sessionRepository := auth.NewSessionRepository(db)

	logoutHandler := httpapi.NewLogoutHandler(sessionRepository)

	server := &http.Server{
		Addr: net.JoinHostPort(cfg.Host, cfg.Port),
		Handler: httpapi.NewConfiguredRouter(
			httpapi.RouterDependencies{
				AuthHandler:          authHandler,
				VerifyHandler:        verifyHandler,
				SessionAuthenticator: sessionRepository,
				LogoutHandler:        logoutHandler,
			},
		),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	serverErrors := make(chan error, 1)

	go func() {
		log.Printf(
			"Private Messenger API listening on %s",
			server.Addr,
		)
		serverErrors <- server.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		log.Println("Shutdown requested")

	case err := <-serverErrors:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Server failed: %v", err)
		}
		return
	}

	shutdownCtx, cancel := context.WithTimeout(
		context.Background(),
		10*time.Second,
	)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("Graceful shutdown failed: %v", err)
	}
}
