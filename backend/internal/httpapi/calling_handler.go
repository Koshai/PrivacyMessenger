package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"example.com/private-messenger/backend/internal/calling"
	"example.com/private-messenger/backend/internal/realtime"

	"github.com/google/uuid"
)

type CallingService interface {
	Initiate(ctx context.Context, callerUserID, callerDeviceID, calleeUserID uuid.UUID, mediaType, clientCallID string) (calling.InitiateResult, error)
	Accept(ctx context.Context, actorUserID, actorDeviceID, callID uuid.UUID) (calling.Session, error)
	Decline(ctx context.Context, actorUserID, callID uuid.UUID) (calling.Session, error)
	Cancel(ctx context.Context, actorUserID, callID uuid.UUID) (calling.Session, error)
	HangUp(ctx context.Context, actorUserID, callID uuid.UUID) (calling.Session, error)
	SetOffer(ctx context.Context, actorUserID, callID uuid.UUID, sdp string) (calling.Session, error)
	SetAnswer(ctx context.Context, actorUserID, callID uuid.UUID, sdp string) (calling.Session, error)
	MarkConnected(ctx context.Context, actorUserID, callID uuid.UUID) (calling.Session, error)
	AddICE(ctx context.Context, actorUserID, callID uuid.UUID, candidate, clientICEID string, sdpMid *string, sdpMLineIndex *int) (calling.ICECandidate, bool, error)
	Get(ctx context.Context, actorUserID, callID uuid.UUID) (calling.Session, error)
	ListICE(ctx context.Context, actorUserID, callID uuid.UUID, afterSeq int64, limit int) ([]calling.ICECandidate, error)
	ActiveForUser(ctx context.Context, userID uuid.UUID) (calling.Session, bool, error)
	EndCallsForUser(ctx context.Context, userID uuid.UUID) error
}

type CallingHandler struct {
	service CallingService
	hub     *realtime.Hub
	purger  interface {
		Purge(ctx context.Context, callID uuid.UUID) error
	}
}

func NewCallingHandler(service CallingService, hub *realtime.Hub) *CallingHandler {
	return &CallingHandler{service: service, hub: hub}
}

func (h *CallingHandler) SetAuthPurger(p interface {
	Purge(ctx context.Context, callID uuid.UUID) error
}) {
	if h != nil {
		h.purger = p
	}
}

func (h *CallingHandler) NotifyCall(userID uuid.UUID, eventType, callID string) {
	if h == nil || h.hub == nil {
		return
	}
	h.hub.NotifyUser(userID, realtime.Event{
		Type:   eventType,
		CallID: callID,
	})
}

func (h *CallingHandler) Initiate(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	var body struct {
		CalleeUserID string `json:"callee_user_id"`
		MediaType    string `json:"media_type"`
		ClientCallID string `json:"client_call_id"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	calleeID, err := uuid.Parse(body.CalleeUserID)
	if err != nil {
		http.Error(w, "invalid callee_user_id", http.StatusBadRequest)
		return
	}
	result, err := h.service.Initiate(
		r.Context(),
		session.UserID,
		session.DeviceID,
		calleeID,
		body.MediaType,
		body.ClientCallID,
	)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	status := http.StatusOK
	if result.Created {
		status = http.StatusCreated
	}
	writeJSON(w, status, mapCall(result.Session))
}

func (h *CallingHandler) Accept(w http.ResponseWriter, r *http.Request) {
	h.mutateCall(w, r, func(ctx context.Context, userID, deviceID, callID uuid.UUID) (calling.Session, error) {
		return h.service.Accept(ctx, userID, deviceID, callID)
	})
}

func (h *CallingHandler) Decline(w http.ResponseWriter, r *http.Request) {
	h.mutateCallNoDevice(w, r, h.service.Decline)
}

func (h *CallingHandler) Cancel(w http.ResponseWriter, r *http.Request) {
	h.mutateCallNoDevice(w, r, h.service.Cancel)
}

func (h *CallingHandler) HangUp(w http.ResponseWriter, r *http.Request) {
	h.mutateCallNoDevice(w, r, h.service.HangUp)
}

func (h *CallingHandler) SetOffer(w http.ResponseWriter, r *http.Request) {
	h.setSDP(w, r, h.service.SetOffer)
}

func (h *CallingHandler) SetAnswer(w http.ResponseWriter, r *http.Request) {
	h.setSDP(w, r, h.service.SetAnswer)
}

func (h *CallingHandler) MarkConnected(w http.ResponseWriter, r *http.Request) {
	h.mutateCallNoDevice(w, r, h.service.MarkConnected)
}

func (h *CallingHandler) AddICE(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	var body struct {
		Candidate     string  `json:"candidate"`
		ClientICEID   string  `json:"client_ice_id"`
		SDPMID        *string `json:"sdp_mid"`
		SDPMLineIndex *int    `json:"sdp_mline_index"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	ice, created, err := h.service.AddICE(
		r.Context(),
		session.UserID,
		callID,
		body.Candidate,
		body.ClientICEID,
		body.SDPMID,
		body.SDPMLineIndex,
	)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, mapICE(ice))
}

func (h *CallingHandler) Get(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	call, err := h.service.Get(r.Context(), session.UserID, callID)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, mapCall(call))
}

func (h *CallingHandler) ListICE(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	items, err := h.service.ListICE(r.Context(), session.UserID, callID, after, limit)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(items))
	for _, ice := range items {
		out = append(out, mapICE(ice))
	}
	writeJSON(w, http.StatusOK, map[string]any{"candidates": out})
}

func (h *CallingHandler) Active(w http.ResponseWriter, r *http.Request) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	call, found, err := h.service.ActiveForUser(r.Context(), session.UserID)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	if !found {
		writeJSON(w, http.StatusOK, map[string]any{"call": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"call": mapCall(call)})
}

func (h *CallingHandler) mutateCall(
	w http.ResponseWriter,
	r *http.Request,
	fn func(ctx context.Context, userID, deviceID, callID uuid.UUID) (calling.Session, error),
) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	call, err := fn(r.Context(), session.UserID, session.DeviceID, callID)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, mapCall(call))
}

func (h *CallingHandler) mutateCallNoDevice(
	w http.ResponseWriter,
	r *http.Request,
	fn func(ctx context.Context, userID, callID uuid.UUID) (calling.Session, error),
) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	call, err := fn(r.Context(), session.UserID, callID)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	if call.State == calling.StateEnded && h.purger != nil {
		_ = h.purger.Purge(r.Context(), callID)
	}
	writeJSON(w, http.StatusOK, mapCall(call))
}

func (h *CallingHandler) setSDP(
	w http.ResponseWriter,
	r *http.Request,
	fn func(ctx context.Context, userID, callID uuid.UUID, sdp string) (calling.Session, error),
) {
	session, ok := SessionFromContext(r.Context())
	if !ok {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	callID, err := uuid.Parse(r.PathValue("callID"))
	if err != nil {
		http.Error(w, "invalid call id", http.StatusBadRequest)
		return
	}
	var body struct {
		SDP string `json:"sdp"`
	}
	if !decodeExactJSON(w, r, &body) {
		return
	}
	call, err := fn(r.Context(), session.UserID, callID, body.SDP)
	if err != nil {
		writeCallingError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, mapCall(call))
}

func mapCall(s calling.Session) map[string]any {
	out := map[string]any{
		"id":               s.ID.String(),
		"caller_user_id":   s.CallerUserID.String(),
		"callee_user_id":   s.CalleeUserID.String(),
		"caller_device_id": s.CallerDeviceID.String(),
		"media_type":       s.MediaType,
		"state":            s.State,
		"client_call_id":   s.ClientCallID,
		"ring_expires_at":  s.RingExpiresAt.UTC(),
		"created_at":       s.CreatedAt.UTC(),
		"updated_at":       s.UpdatedAt.UTC(),
		"version":          s.Version,
	}
	if s.CalleeDeviceID != nil {
		out["callee_device_id"] = s.CalleeDeviceID.String()
	}
	if s.EndReason != nil {
		out["end_reason"] = *s.EndReason
	}
	if s.SDPOffer != nil {
		out["sdp_offer"] = *s.SDPOffer
	}
	if s.SDPAnswer != nil {
		out["sdp_answer"] = *s.SDPAnswer
	}
	if s.AcceptedAt != nil {
		out["accepted_at"] = s.AcceptedAt.UTC()
	}
	if s.EndedAt != nil {
		out["ended_at"] = s.EndedAt.UTC()
	}
	return out
}

func mapICE(ice calling.ICECandidate) map[string]any {
	out := map[string]any{
		"id":             ice.ID.String(),
		"call_id":        ice.CallID.String(),
		"sender_user_id": ice.SenderUserID.String(),
		"seq":            ice.Seq,
		"candidate":      ice.Candidate,
		"client_ice_id":  ice.ClientICEID,
		"created_at":     ice.CreatedAt.UTC(),
	}
	if ice.SDPMID != nil {
		out["sdp_mid"] = *ice.SDPMID
	}
	if ice.SDPMLineIndex != nil {
		out["sdp_mline_index"] = *ice.SDPMLineIndex
	}
	return out
}

func writeCallingError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, calling.ErrInvalidInput):
		http.Error(w, "invalid input", http.StatusBadRequest)
	case errors.Is(err, calling.ErrNotAuthorized):
		http.Error(w, "not authorized", http.StatusForbidden)
	case errors.Is(err, calling.ErrNotAvailable):
		// Identical response for blocked and non-friend (privacy).
		http.Error(w, "call not available", http.StatusNotFound)
	case errors.Is(err, calling.ErrCallMissing):
		http.Error(w, "call not found", http.StatusNotFound)
	case errors.Is(err, calling.ErrIllegalTransition), errors.Is(err, calling.ErrCallExpired):
		http.Error(w, "illegal call state", http.StatusConflict)
	case errors.Is(err, calling.ErrBusy):
		http.Error(w, "busy", http.StatusConflict)
	case errors.Is(err, calling.ErrDeviceConflict):
		http.Error(w, "device conflict", http.StatusConflict)
	case errors.Is(err, calling.ErrStaleUpdate):
		http.Error(w, "stale call state", http.StatusConflict)
	case errors.Is(err, calling.ErrCleanupFailed):
		http.Error(w, "cleanup failed", http.StatusInternalServerError)
	case errors.Is(err, calling.ErrPayloadTooLarge):
		http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
	case errors.Is(err, calling.ErrRateLimited):
		http.Error(w, "rate limited", http.StatusTooManyRequests)
	case errors.Is(err, calling.ErrReplay):
		http.Error(w, "replay rejected", http.StatusConflict)
	default:
		http.Error(w, "calling error", http.StatusInternalServerError)
	}
}
