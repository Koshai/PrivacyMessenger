package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"example.com/private-messenger/backend/internal/friends"

	"github.com/google/uuid"
)

type FriendsService interface {
	RequestByEmail(ctx context.Context, requesterID uuid.UUID, email string) error
	Accept(ctx context.Context, actorID, requestID uuid.UUID) error
	Reject(ctx context.Context, actorID, requestID uuid.UUID) error
	RemoveFriend(ctx context.Context, actorID, friendUserID uuid.UUID) error
	ListFriends(ctx context.Context, actorID uuid.UUID) ([]friends.FriendSummary, error)
	FriendCount(ctx context.Context, actorID uuid.UUID) (int, error)
	ListIncoming(ctx context.Context, actorID uuid.UUID) ([]friends.PendingRequest, error)
	ListOutgoing(ctx context.Context, actorID uuid.UUID) ([]friends.PendingRequest, error)
	BlockByUserID(ctx context.Context, actorID, targetID uuid.UUID) error
	Unblock(ctx context.Context, actorID, targetID uuid.UUID) error
	ListBlocked(ctx context.Context, actorID uuid.UUID) ([]friends.BlockRecord, error)
}

type FriendsHandler struct {
	service FriendsService
}

func NewFriendsHandler(service FriendsService) *FriendsHandler {
	return &FriendsHandler{service: service}
}

type friendRequestBody struct {
	Email string `json:"email"`
}

type friendUserBody struct {
	UserID string `json:"user_id"`
}

type friendSummaryResponse struct {
	UserID string    `json:"user_id"`
	Email  string    `json:"email"`
	Since  time.Time `json:"since"`
}

type pendingRequestResponse struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
	Outgoing  bool      `json:"outgoing"`
}

type blockResponse struct {
	UserID    string    `json:"user_id"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

func (h *FriendsHandler) CreateRequest(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	var body friendRequestBody
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(w, "request must contain exactly one JSON object", http.StatusBadRequest)
		return
	}

	err := h.service.RequestByEmail(r.Context(), session.UserID, body.Email)
	if err != nil {
		// Defense in depth: never distinguish relationship existence from
		// unknown accounts via 409 on this endpoint.
		if errors.Is(err, friends.ErrAlreadyFriends) ||
			errors.Is(err, friends.ErrRequestAlreadyPending) {
			writeFriendRequestAccepted(w)
			return
		}
		writeFriendsError(w, err)
		return
	}

	writeFriendRequestAccepted(w)
}

func writeFriendRequestAccepted(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"message": "If that account exists, a friend request was submitted.",
	})
}

func (h *FriendsHandler) ListFriends(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	items, err := h.service.ListFriends(r.Context(), session.UserID)
	if err != nil {
		writeFriendsError(w, err)
		return
	}

	response := make([]friendSummaryResponse, 0, len(items))
	for _, item := range items {
		response = append(response, friendSummaryResponse{
			UserID: item.UserID.String(),
			Email:  item.Email,
			Since:  item.Since.UTC(),
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"friends": response})
}

func (h *FriendsHandler) FriendCount(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	count, err := h.service.FriendCount(r.Context(), session.UserID)
	if err != nil {
		writeFriendsError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"count": count})
}

func (h *FriendsHandler) ListIncoming(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	items, err := h.service.ListIncoming(r.Context(), session.UserID)
	if err != nil {
		writeFriendsError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"requests": mapPending(items),
	})
}

func (h *FriendsHandler) ListOutgoing(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	items, err := h.service.ListOutgoing(r.Context(), session.UserID)
	if err != nil {
		writeFriendsError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"requests": mapPending(items),
	})
}

func (h *FriendsHandler) Accept(w http.ResponseWriter, r *http.Request) {
	h.transitionRequest(w, r, h.service.Accept)
}

func (h *FriendsHandler) Reject(w http.ResponseWriter, r *http.Request) {
	h.transitionRequest(w, r, h.service.Reject)
}

func (h *FriendsHandler) transitionRequest(
	w http.ResponseWriter,
	r *http.Request,
	action func(context.Context, uuid.UUID, uuid.UUID) error,
) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	requestID, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		http.Error(w, "invalid request id", http.StatusBadRequest)
		return
	}

	if err := action(r.Context(), session.UserID, requestID); err != nil {
		writeFriendsError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *FriendsHandler) RemoveFriend(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	friendID, err := uuid.Parse(r.PathValue("userID"))
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}

	if err := h.service.RemoveFriend(r.Context(), session.UserID, friendID); err != nil {
		writeFriendsError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *FriendsHandler) Block(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	var body friendUserBody
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(w, "request must contain exactly one JSON object", http.StatusBadRequest)
		return
	}

	targetID, err := uuid.Parse(body.UserID)
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}

	if err := h.service.BlockByUserID(r.Context(), session.UserID, targetID); err != nil {
		writeFriendsError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *FriendsHandler) Unblock(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	targetID, err := uuid.Parse(r.PathValue("userID"))
	if err != nil {
		http.Error(w, "invalid user id", http.StatusBadRequest)
		return
	}

	if err := h.service.Unblock(r.Context(), session.UserID, targetID); err != nil {
		writeFriendsError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *FriendsHandler) ListBlocked(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}

	items, err := h.service.ListBlocked(r.Context(), session.UserID)
	if err != nil {
		writeFriendsError(w, err)
		return
	}

	response := make([]blockResponse, 0, len(items))
	for _, item := range items {
		response = append(response, blockResponse{
			UserID:    item.BlockedUserID.String(),
			Email:     item.Email,
			CreatedAt: item.CreatedAt.UTC(),
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"blocked": response})
}

func mapPending(items []friends.PendingRequest) []pendingRequestResponse {
	response := make([]pendingRequestResponse, 0, len(items))
	for _, item := range items {
		response = append(response, pendingRequestResponse{
			ID:        item.ID.String(),
			UserID:    item.UserID.String(),
			Email:     item.Email,
			CreatedAt: item.CreatedAt.UTC(),
			Outgoing:  item.Outgoing,
		})
	}
	return response
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeFriendsError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, friends.ErrInvalidInput),
		errors.Is(err, friends.ErrSelfRelationship):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case errors.Is(err, friends.ErrAlreadyFriends),
		errors.Is(err, friends.ErrRequestAlreadyPending):
		http.Error(w, err.Error(), http.StatusConflict)
	case errors.Is(err, friends.ErrNotAuthorized):
		http.Error(w, err.Error(), http.StatusForbidden)
	case errors.Is(err, friends.ErrRequestNotFound),
		errors.Is(err, friends.ErrNotFriends),
		errors.Is(err, friends.ErrUserUnavailable):
		http.Error(w, err.Error(), http.StatusNotFound)
	case errors.Is(err, friends.ErrBlocked):
		http.Error(w, err.Error(), http.StatusConflict)
	case errors.Is(err, friends.ErrRateLimited):
		http.Error(w, err.Error(), http.StatusTooManyRequests)
	default:
		http.Error(w, "friends operation failed", http.StatusInternalServerError)
	}
}
