package auth

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

type SMTPConfig struct {
	Host     string
	Port     int
	Username string
	Password string
	From     string
	FromName string
}

type SMTPOTPSender struct {
	config SMTPConfig
}

func NewSMTPOTPSender(cfg SMTPConfig) (*SMTPOTPSender, error) {
	if cfg.Host == "" || cfg.Username == "" ||
		cfg.Password == "" || cfg.Port <= 0 {
		return nil, errors.New("incomplete SMTP configuration")
	}
	if strings.ContainsAny(cfg.Host, "\r\n") {
		return nil, errors.New("invalid SMTP host")
	}
	if _, err := mail.ParseAddress(cfg.From); err != nil {
		return nil, errors.New("invalid SMTP sender address")
	}
	if strings.ContainsAny(cfg.FromName, "\r\n") {
		return nil, errors.New("invalid SMTP sender name")
	}
	return &SMTPOTPSender{config: cfg}, nil
}

func (s *SMTPOTPSender) SendOTP(
	ctx context.Context,
	message OTPMessage,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(message.Code) != 6 {
		return errors.New("invalid OTP length")
	}
	for _, c := range message.Code {
		if c < '0' || c > '9' {
			return errors.New("invalid OTP characters")
		}
	}

	recipient, err := mail.ParseAddress(message.Email)
	if err != nil || recipient.Address != message.Email {
		return errors.New("invalid recipient address")
	}

	cfg := s.config
	address := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))

	dialer := net.Dialer{Timeout: 10 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return errors.New("SMTP connection failed")
	}
	defer conn.Close()

	// Bound the entire SMTP conversation.
	deadline := time.Now().Add(15 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() {
		_ = conn.Close()
	})
	defer stop()

	client, err := smtp.NewClient(conn, cfg.Host)
	if err != nil {
		return errors.New("SMTP handshake failed")
	}
	defer client.Close()

	if ok, _ := client.Extension("STARTTLS"); !ok {
		return errors.New("SMTP server does not support STARTTLS")
	}

	if err := client.StartTLS(&tls.Config{
		ServerName: cfg.Host,
		MinVersion: tls.VersionTLS12,
	}); err != nil {
		return errors.New("SMTP TLS negotiation failed")
	}

	auth := smtp.PlainAuth(
		"",
		cfg.Username,
		cfg.Password,
		cfg.Host,
	)
	if err := client.Auth(auth); err != nil {
		return errors.New("SMTP authentication failed")
	}

	if err := client.Mail(cfg.From); err != nil {
		return errors.New("SMTP sender rejected")
	}
	if err := client.Rcpt(recipient.Address); err != nil {
		return errors.New("SMTP recipient rejected")
	}

	writer, err := client.Data()
	if err != nil {
		return errors.New("SMTP message rejected")
	}

	fromHeader := (&mail.Address{
		Name: cfg.FromName, Address: cfg.From,
	}).String()

	body := fmt.Sprintf(
		"Your PrivateMessenger verification code is: %s\r\n\r\n"+
			"This code expires at %s.\r\n"+
			"If you did not request this code, ignore this email.\r\n",
		message.Code,
		message.ExpiresAt.UTC().Format(time.RFC1123),
	)

	email := "From: " + fromHeader + "\r\n" +
		"To: " + recipient.String() + "\r\n" +
		"Subject: PrivateMessenger verification code\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n" +
		"\r\n" + body

	if _, err := writer.Write([]byte(email)); err != nil {
		_ = writer.Close()
		return errors.New("SMTP message transmission failed")
	}
	if err := writer.Close(); err != nil {
		return errors.New("SMTP message delivery not accepted")
	}

	_ = client.Quit()
	return nil
}
