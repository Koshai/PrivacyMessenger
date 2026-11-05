package calling

import (
	"context"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Service struct {
	store       Store
	friends     FriendshipChecker
	blocks      BlockChecker
	notifier    Notifier
	limiter     *RateLimiter
	now         func() time.Time
	ringTimeout time.Duration
}

func NewService(
	store Store,
	friends FriendshipChecker,
	blocks BlockChecker,
) *Service {
	return &Service{
		store:       store,
		friends:     friends,
		blocks:      blocks,
		limiter:     NewRateLimiter(SignalingRateLimit, SignalingRateWindow),
		now:         time.Now,
		ringTimeout: DefaultRingTimeout,
	}
}

func (s *Service) WithNotifier(n Notifier) *Service {
	s.notifier = n
	return s
}

func (s *Service) allow(userID uuid.UUID) error {
	if s.limiter != nil && !s.limiter.Allow(userID) {
		return ErrRateLimited
	}
	return nil
}

func (s *Service) Initiate(
	ctx context.Context,
	callerUserID, callerDeviceID, calleeUserID uuid.UUID,
	mediaType, clientCallID string,
) (InitiateResult, error) {
	if err := s.allow(callerUserID); err != nil {
		return InitiateResult{}, err
	}
	mediaType = strings.TrimSpace(mediaType)
	clientCallID = strings.TrimSpace(clientCallID)
	if callerUserID == uuid.Nil || calleeUserID == uuid.Nil || callerDeviceID == uuid.Nil {
		return InitiateResult{}, ErrInvalidInput
	}
	if callerUserID == calleeUserID {
		return InitiateResult{}, ErrInvalidInput
	}
	if mediaType != MediaAudio && mediaType != MediaVideo {
		return InitiateResult{}, ErrInvalidInput
	}
	if clientCallID == "" || len(clientCallID) > 128 {
		return InitiateResult{}, ErrInvalidInput
	}

	if existing, err := s.store.GetByCallerClientID(ctx, callerUserID, clientCallID); err == nil {
		if existing.CalleeUserID != calleeUserID ||
			existing.CallerDeviceID != callerDeviceID ||
			existing.MediaType != mediaType {
			return InitiateResult{}, ErrReplay
		}
		return InitiateResult{Session: existing, Created: false}, nil
	}

	if err := s.authorizePair(ctx, callerUserID, calleeUserID); err != nil {
		return InitiateResult{}, err
	}

	now := s.now().UTC()
	session := Session{
		ID:             uuid.New(),
		CallerUserID:   callerUserID,
		CalleeUserID:   calleeUserID,
		CallerDeviceID: callerDeviceID,
		MediaType:      mediaType,
		State:          StateRinging,
		ClientCallID:   clientCallID,
		RingExpiresAt:  now.Add(s.ringTimeout),
		CreatedAt:      now,
		UpdatedAt:      now,
		Version:        0,
	}
	created, err := s.store.CreateSessionExclusive(ctx, session)
	if err != nil {
		return InitiateResult{}, err
	}
	wasCreated := created.ID == session.ID
	if wasCreated {
		s.notify(calleeUserID, "call.ringing", created.ID)
		s.notify(callerUserID, "call.ringing", created.ID)
	} else if created.CalleeUserID != calleeUserID ||
		created.CallerDeviceID != callerDeviceID ||
		created.MediaType != mediaType {
		return InitiateResult{}, ErrReplay
	}
	return InitiateResult{Session: created, Created: wasCreated}, nil
}

func (s *Service) Accept(
	ctx context.Context,
	actorUserID, actorDeviceID, callID uuid.UUID,
) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.CalleeUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	if session.State == StateAccepted || session.State == StateConnected {
		if session.CalleeDeviceID != nil && *session.CalleeDeviceID != actorDeviceID {
			return Session{}, ErrDeviceConflict
		}
		return session, nil
	}
	if session.State != StateRinging {
		return Session{}, ErrIllegalTransition
	}
	if err := s.ensureNotExpired(ctx, &session); err != nil {
		return Session{}, err
	}
	expected := session.Version
	now := s.now().UTC()
	session.State = StateAccepted
	session.CalleeDeviceID = &actorDeviceID
	session.AcceptedAt = &now
	session.UpdatedAt = now
	updated, err := s.store.UpdateSessionIfVersion(ctx, expected, session)
	if err != nil {
		return Session{}, err
	}
	s.notify(session.CallerUserID, "call.accepted", updated.ID)
	return updated, nil
}

func (s *Service) Decline(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.CalleeUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	if session.State == StateEnded && session.EndReason != nil && *session.EndReason == EndDeclined {
		return session, nil
	}
	if session.State != StateRinging {
		return Session{}, ErrIllegalTransition
	}
	return s.endCall(ctx, session, EndDeclined)
}

func (s *Service) Cancel(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.CallerUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	if session.State == StateEnded && session.EndReason != nil && *session.EndReason == EndCancelled {
		return session, nil
	}
	if session.State != StateRinging {
		return Session{}, ErrIllegalTransition
	}
	return s.endCall(ctx, session, EndCancelled)
}

func (s *Service) HangUp(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.State == StateEnded && session.EndReason != nil && *session.EndReason == EndHangup {
		return session, nil
	}
	if session.State != StateAccepted && session.State != StateConnected && session.State != StateRinging {
		return Session{}, ErrIllegalTransition
	}
	if session.State == StateRinging && session.CallerUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	reason := EndHangup
	if session.State == StateRinging {
		reason = EndCancelled
	}
	return s.endCall(ctx, session, reason)
}

func (s *Service) SetOffer(ctx context.Context, actorUserID, callID uuid.UUID, sdp string) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	sdp = strings.TrimSpace(sdp)
	if sdp == "" {
		return Session{}, ErrInvalidInput
	}
	if len(sdp) > MaxSDPPChars {
		return Session{}, ErrPayloadTooLarge
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.CallerUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	if session.State != StateRinging && session.State != StateAccepted {
		return Session{}, ErrIllegalTransition
	}
	if session.SDPOffer != nil && *session.SDPOffer == sdp {
		return session, nil
	}
	if session.SDPOffer != nil && *session.SDPOffer != sdp {
		return Session{}, ErrReplay
	}
	expected := session.Version
	now := s.now().UTC()
	session.SDPOffer = &sdp
	session.UpdatedAt = now
	updated, err := s.store.UpdateSessionIfVersion(ctx, expected, session)
	if err != nil {
		return Session{}, err
	}
	s.notify(session.CalleeUserID, "call.offer", updated.ID)
	return updated, nil
}

func (s *Service) SetAnswer(ctx context.Context, actorUserID, callID uuid.UUID, sdp string) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	sdp = strings.TrimSpace(sdp)
	if sdp == "" {
		return Session{}, ErrInvalidInput
	}
	if len(sdp) > MaxSDPPChars {
		return Session{}, ErrPayloadTooLarge
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.CalleeUserID != actorUserID {
		return Session{}, ErrNotAuthorized
	}
	if session.State != StateAccepted && session.State != StateConnected {
		return Session{}, ErrIllegalTransition
	}
	if session.SDPOffer == nil {
		return Session{}, ErrIllegalTransition
	}
	if session.SDPAnswer != nil && *session.SDPAnswer == sdp {
		return session, nil
	}
	if session.SDPAnswer != nil && *session.SDPAnswer != sdp {
		return Session{}, ErrReplay
	}
	expected := session.Version
	now := s.now().UTC()
	session.SDPAnswer = &sdp
	// Answer advances negotiation only — stay accepted unless already connected.
	if session.State != StateConnected {
		session.State = StateAccepted
	}
	session.UpdatedAt = now
	updated, err := s.store.UpdateSessionIfVersion(ctx, expected, session)
	if err != nil {
		return Session{}, err
	}
	s.notify(session.CallerUserID, "call.answer", updated.ID)
	return updated, nil
}

// MarkConnected records a client-reported WebRTC connection indication.
// The server does not verify media delivery.
func (s *Service) MarkConnected(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	if err := s.allow(actorUserID); err != nil {
		return Session{}, err
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return Session{}, err
	}
	if session.State == StateConnected {
		return session, nil
	}
	if session.State != StateAccepted {
		return Session{}, ErrIllegalTransition
	}
	if session.SDPOffer == nil || session.SDPAnswer == nil {
		return Session{}, ErrIllegalTransition
	}
	expected := session.Version
	now := s.now().UTC()
	session.State = StateConnected
	session.UpdatedAt = now
	updated, err := s.store.UpdateSessionIfVersion(ctx, expected, session)
	if err != nil {
		return Session{}, err
	}
	s.notify(session.CallerUserID, "call.connected", updated.ID)
	s.notify(session.CalleeUserID, "call.connected", updated.ID)
	return updated, nil
}

func (s *Service) AddICE(
	ctx context.Context,
	actorUserID, callID uuid.UUID,
	candidate, clientICEID string,
	sdpMid *string,
	sdpMLineIndex *int,
) (ICECandidate, bool, error) {
	if err := s.allow(actorUserID); err != nil {
		return ICECandidate{}, false, err
	}
	candidate = strings.TrimSpace(candidate)
	clientICEID = strings.TrimSpace(clientICEID)
	if candidate == "" || clientICEID == "" {
		return ICECandidate{}, false, ErrInvalidInput
	}
	if len(candidate) > MaxICECandidateLen || len(clientICEID) > 128 {
		return ICECandidate{}, false, ErrPayloadTooLarge
	}
	if sdpMid != nil && len(*sdpMid) > 256 {
		return ICECandidate{}, false, ErrPayloadTooLarge
	}
	session, err := s.loadAuthorized(ctx, actorUserID, callID)
	if err != nil {
		return ICECandidate{}, false, err
	}
	if session.State != StateRinging && session.State != StateAccepted && session.State != StateConnected {
		return ICECandidate{}, false, ErrIllegalTransition
	}
	ice := ICECandidate{
		ID:            uuid.New(),
		CallID:        callID,
		SenderUserID:  actorUserID,
		Candidate:     candidate,
		SDPMID:        sdpMid,
		SDPMLineIndex: sdpMLineIndex,
		ClientICEID:   clientICEID,
		CreatedAt:     s.now().UTC(),
	}
	stored, created, err := s.store.InsertICEExclusive(ctx, ice)
	if err != nil {
		return ICECandidate{}, false, err
	}
	if created {
		if peer, ok := session.Peer(actorUserID); ok {
			s.notify(peer, "call.ice", callID)
		}
	}
	return stored, created, nil
}

func (s *Service) Get(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	return s.loadAuthorized(ctx, actorUserID, callID)
}

func (s *Service) ListICE(
	ctx context.Context,
	actorUserID, callID uuid.UUID,
	afterSeq int64,
	limit int,
) ([]ICECandidate, error) {
	if _, err := s.loadAuthorized(ctx, actorUserID, callID); err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	return s.store.ListICEAfter(ctx, callID, afterSeq, limit)
}

func (s *Service) ActiveForUser(ctx context.Context, userID uuid.UUID) (Session, bool, error) {
	return s.store.FindActiveForUser(ctx, userID)
}

func (s *Service) EndCallsForUser(ctx context.Context, userID uuid.UUID) error {
	for {
		session, ok, err := s.store.FindActiveForUser(ctx, userID)
		if err != nil {
			return err
		}
		if !ok {
			return nil
		}
		if _, err := s.endCall(ctx, session, EndRevoked); err != nil {
			return err
		}
	}
}

func (s *Service) ExpireRinging(ctx context.Context) (int, error) {
	now := s.now().UTC()
	expired, err := s.store.ListExpiredRinging(ctx, now, 100)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, session := range expired {
		if session.State != StateRinging {
			continue
		}
		if _, err := s.endCall(ctx, session, EndTimeout); err != nil {
			if err == ErrStaleUpdate {
				continue
			}
			return n, err
		}
		n++
	}
	return n, nil
}

func (s *Service) authorizePair(ctx context.Context, a, b uuid.UUID) error {
	if s.blocks != nil {
		blocked, err := s.blocks.IsBlockedEitherWay(ctx, a, b)
		if err != nil {
			return err
		}
		if blocked {
			return ErrNotAvailable
		}
	}
	ok, err := s.friends.AreAcceptedFriends(ctx, a, b)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotAvailable
	}
	return nil
}

func (s *Service) loadAuthorized(ctx context.Context, actorUserID, callID uuid.UUID) (Session, error) {
	session, err := s.store.GetByID(ctx, callID)
	if err != nil {
		return Session{}, err
	}
	if !session.Participant(actorUserID) {
		return Session{}, ErrNotAuthorized
	}
	return session, nil
}

func (s *Service) ensureNotExpired(ctx context.Context, session *Session) error {
	if session.State != StateRinging {
		return nil
	}
	if !s.now().UTC().After(session.RingExpiresAt) {
		return nil
	}
	ended, err := s.endCall(ctx, *session, EndTimeout)
	if err != nil {
		return err
	}
	*session = ended
	return ErrCallExpired
}

func (s *Service) endCall(ctx context.Context, session Session, reason string) (Session, error) {
	if session.State == StateEnded {
		return session, nil
	}
	expected := session.Version
	now := s.now().UTC()
	session.State = StateEnded
	session.EndReason = &reason
	session.EndedAt = &now
	session.UpdatedAt = now
	session.SDPOffer = nil
	session.SDPAnswer = nil
	updated, err := s.store.EndSessionAtomic(ctx, expected, session)
	if err != nil {
		return Session{}, err
	}
	s.notify(session.CallerUserID, "call.ended", updated.ID)
	s.notify(session.CalleeUserID, "call.ended", updated.ID)
	return updated, nil
}

func (s *Service) notify(userID uuid.UUID, eventType string, callID uuid.UUID) {
	if s.notifier == nil {
		return
	}
	s.notifier.NotifyCall(userID, eventType, callID.String())
}
