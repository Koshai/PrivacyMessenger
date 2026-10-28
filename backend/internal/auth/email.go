package auth

import (
	"errors"
	"net/mail"
	"strings"
	"unicode/utf8"
)

var ErrInvalidEmail = errors.New("invalid email address")

func NormalizeEmail(email string) (string, error) {
	email = strings.TrimSpace(email)

	if email == "" || len(email) > 320 {
		return "", ErrInvalidEmail
	}

	if !utf8.ValidString(email) {
		return "", ErrInvalidEmail
	}

	if strings.ContainsAny(email, " \t\r\n") {
		return "", ErrInvalidEmail
	}

	address, err := mail.ParseAddress(email)
	if err != nil {
		return "", ErrInvalidEmail
	}

	// Reject display-name formats such as:
	// "John Smith <john@example.com>"
	if address.Address != email {
		return "", ErrInvalidEmail
	}

	parts := strings.Split(email, "@")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", ErrInvalidEmail
	}

	// Application identity policy:
	// treat ASCII case variants as the same account.
	// Do not strip dots or +tags; those are provider-specific.
	normalized := strings.ToLower(email)

	return normalized, nil
}
