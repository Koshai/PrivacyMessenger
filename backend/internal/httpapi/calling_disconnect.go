package httpapi

import (
	"context"

	"github.com/google/uuid"
)

// CallTerminator ends active calls when a session is revoked/logged out.
type CallTerminator interface {
	EndCallsForUser(ctx context.Context, userID uuid.UUID) error
}
