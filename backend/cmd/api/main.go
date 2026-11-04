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
	"strconv"
	"strings"
	"syscall"
	"time"

	"example.com/private-messenger/backend/internal/auth"
	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/config"
	appcrypto "example.com/private-messenger/backend/internal/crypto"
	"example.com/private-messenger/backend/internal/friends"
	"example.com/private-messenger/backend/internal/httpapi"
	"example.com/private-messenger/backend/internal/messaging"
	"example.com/private-messenger/backend/internal/realtime"

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

	smtpPort, err := strconv.Atoi(os.Getenv("SMTP_PORT"))
	if err != nil {
		log.Fatal("SMTP_PORT must be a valid integer")
	}

	sender, err := auth.NewSMTPOTPSender(auth.SMTPConfig{
		Host:     os.Getenv("SMTP_HOST"),
		Port:     smtpPort,
		Username: os.Getenv("SMTP_USERNAME"),
		Password: os.Getenv("SMTP_PASSWORD"),
		From:     os.Getenv("SMTP_FROM_EMAIL"),
		FromName: os.Getenv("SMTP_FROM_NAME"),
	})
	if err != nil {
		log.Fatalf("SMTP configuration failed: %v", err)
	}

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

	hub := realtime.NewHub()
	realtimeHandler := httpapi.NewRealtimeHandler(hub, sessionRepository)

	friendsService := friends.NewService(db)
	friendsHandler := httpapi.NewFriendsHandler(friendsService)

	messagingInner := messaging.NewService(
		messaging.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
	)
	messagingService := messaging.NewNotifyingService(messagingInner, realtimeHandler)
	messagingHandler := httpapi.NewMessagingHandler(messagingService)

	cryptoService := appcrypto.NewService(
		appcrypto.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		appcrypto.NewPostgresDeviceOwnerChecker(db),
	)
	cryptoHandler := httpapi.NewCryptoHandler(cryptoService)

	callingService := calling.NewService(
		calling.NewRepository(db),
		messaging.NewPostgresFriendshipChecker(db),
		calling.NewPostgresBlockChecker(db),
	)
	callingHandler := httpapi.NewCallingHandler(callingService, hub)
	callingService.WithNotifier(callingHandler)

	logoutHandler := httpapi.NewLogoutHandler(sessionRepository).
		WithDisconnecter(realtimeHandler).
		WithCallEnder(callingService)

	// Expire unanswered ringing calls (D1 timeout handling).
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if _, err := callingService.ExpireRinging(context.Background()); err != nil {
				log.Printf("call ring expiry: %v", err)
			}
		}
	}()

	tlsCert := strings.TrimSpace(os.Getenv("TLS_CERT_FILE"))
	tlsKey := strings.TrimSpace(os.Getenv("TLS_KEY_FILE"))
	requireTLS := strings.EqualFold(os.Getenv("REQUIRE_TLS"), "true") ||
		strings.EqualFold(os.Getenv("APP_ENV"), "production")
	if requireTLS && (tlsCert == "" || tlsKey == "") {
		log.Fatal("production/REQUIRE_TLS requires TLS_CERT_FILE and TLS_KEY_FILE")
	}

	router := httpapi.NewConfiguredRouter(
		httpapi.RouterDependencies{
			AuthHandler:          authHandler,
			VerifyHandler:        verifyHandler,
			SessionAuthenticator: sessionRepository,
			LogoutHandler:        logoutHandler,
			FriendsHandler:       friendsHandler,
			MessagingHandler:     messagingHandler,
			CryptoHandler:        cryptoHandler,
			RealtimeHandler:      realtimeHandler,
			CallingHandler:       callingHandler,
		},
	)

	server := &http.Server{
		Addr:              net.JoinHostPort(cfg.Host, cfg.Port),
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
	}
	httpapi.AttachRedactingErrorLog(server)

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	serverErrors := make(chan error, 1)

	go func() {
		if tlsCert != "" && tlsKey != "" {
			log.Printf(
				"Private Messenger API listening on https://%s (TLS)",
				server.Addr,
			)
			serverErrors <- server.ListenAndServeTLS(tlsCert, tlsKey)
			return
		}
		log.Printf(
			"Private Messenger API listening on http://%s",
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
