package calling

import "github.com/google/uuid"

// Notifier pushes call lifecycle hints over the existing realtime hub.
// Clients must still fetch authoritative state via HTTP.
type Notifier interface {
	NotifyCall(userID uuid.UUID, eventType, callID string)
}
