package calling

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

type memFriends struct {
	ok map[[2]uuid.UUID]bool
}

func (m *memFriends) AreAcceptedFriends(_ context.Context, a, b uuid.UUID) (bool, error) {
	return m.ok[[2]uuid.UUID{a, b}] || m.ok[[2]uuid.UUID{b, a}], nil
}

type memBlocks struct {
	blocked map[[2]uuid.UUID]bool
}

func (m *memBlocks) IsBlockedEitherWay(_ context.Context, a, b uuid.UUID) (bool, error) {
	return m.blocked[[2]uuid.UUID{a, b}] || m.blocked[[2]uuid.UUID{b, a}], nil
}

type memNotify struct {
	events []string
}

func (m *memNotify) NotifyCall(userID uuid.UUID, eventType, callID string) {
	m.events = append(m.events, eventType+":"+userID.String()+":"+callID)
}

func newTestService(t *testing.T) (*Service, *memoryStore, uuid.UUID, uuid.UUID, uuid.UUID, uuid.UUID, *memNotify) {
	t.Helper()
	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	store := NewMemoryStore().(*memoryStore)
	friends := &memFriends{ok: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	blocks := &memBlocks{blocked: map[[2]uuid.UUID]bool{}}
	n := &memNotify{}
	svc := NewService(store, friends, blocks).WithNotifier(n)
	return svc, store, alice, bob, aliceDev, bobDev, n
}

func TestInitiateAcceptOfferAnswerHangup(t *testing.T) {
	svc, _, alice, bob, aliceDev, bobDev, n := newTestService(t)
	ctx := context.Background()

	res, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "c1")
	if err != nil || !res.Created || res.Session.State != StateRinging {
		t.Fatalf("initiate: %#v %v", res, err)
	}
	again, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "c1")
	if err != nil || again.Created || again.Session.ID != res.Session.ID {
		t.Fatalf("idempotent initiate failed: %#v %v", again, err)
	}

	accepted, err := svc.Accept(ctx, bob, bobDev, res.Session.ID)
	if err != nil || accepted.State != StateAccepted {
		t.Fatalf("accept: %#v %v", accepted, err)
	}
	accepted2, err := svc.Accept(ctx, bob, bobDev, res.Session.ID)
	if err != nil || accepted2.ID != accepted.ID {
		t.Fatalf("idempotent accept: %v", err)
	}

	offerSDP := "v=0\r\noffer"
	withOffer, err := svc.SetOffer(ctx, alice, res.Session.ID, offerSDP)
	if err != nil || withOffer.SDPOffer == nil || *withOffer.SDPOffer != offerSDP {
		t.Fatalf("offer: %#v %v", withOffer, err)
	}
	if _, err := svc.SetOffer(ctx, alice, res.Session.ID, "different"); err != ErrReplay {
		t.Fatalf("want replay err, got %v", err)
	}

	answerSDP := "v=0\r\nanswer"
	connected, err := svc.SetAnswer(ctx, bob, res.Session.ID, answerSDP)
	if err != nil || connected.State != StateConnected {
		t.Fatalf("answer: %#v %v", connected, err)
	}

	mid := "0"
	idx := 0
	ice, created, err := svc.AddICE(ctx, alice, res.Session.ID, "candidate:1", "ice-1", &mid, &idx)
	if err != nil || !created || ice.Seq != 1 {
		t.Fatalf("ice: %#v %v created=%v", ice, err, created)
	}
	_, created, err = svc.AddICE(ctx, alice, res.Session.ID, "candidate:1", "ice-1", &mid, &idx)
	if err != nil || created {
		t.Fatalf("duplicate ice should be idempotent")
	}

	ended, err := svc.HangUp(ctx, alice, res.Session.ID)
	if err != nil || ended.State != StateEnded || ended.EndReason == nil || *ended.EndReason != EndHangup {
		t.Fatalf("hangup: %#v %v", ended, err)
	}
	if ended.SDPOffer != nil || ended.SDPAnswer != nil {
		t.Fatal("signaling material must be cleared on end")
	}
	if len(n.events) == 0 {
		t.Fatal("expected notifications")
	}
}

func TestRejectNonFriendAndBlocked(t *testing.T) {
	svc, _, alice, _, aliceDev, _, _ := newTestService(t)
	stranger := uuid.New()
	_, err := svc.Initiate(context.Background(), alice, aliceDev, stranger, MediaAudio, "x")
	if err != ErrNotFriends {
		t.Fatalf("want not friends, got %v", err)
	}

	svc2, _, a, b, adev, _, _ := newTestService(t)
	svc2.blocks = &memBlocks{blocked: map[[2]uuid.UUID]bool{{a, b}: true}}
	_, err = svc2.Initiate(context.Background(), a, adev, b, MediaAudio, "y")
	if err != ErrBlocked {
		t.Fatalf("want blocked, got %v", err)
	}
}

func TestBusyAndIllegalTransitions(t *testing.T) {
	svc, _, alice, bob, aliceDev, bobDev, _ := newTestService(t)
	ctx := context.Background()
	first, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaVideo, "busy-1")
	if err != nil {
		t.Fatal(err)
	}
	_, err = svc.Initiate(ctx, alice, aliceDev, bob, MediaVideo, "busy-2")
	if err != ErrBusy {
		t.Fatalf("want busy, got %v", err)
	}
	if _, err := svc.Decline(ctx, alice, first.Session.ID); err != ErrNotAuthorized {
		t.Fatalf("caller cannot decline: %v", err)
	}
	if _, err := svc.Cancel(ctx, bob, first.Session.ID); err != ErrNotAuthorized {
		t.Fatalf("callee cannot cancel: %v", err)
	}
	if _, err := svc.SetAnswer(ctx, bob, first.Session.ID, "sdp"); err != ErrIllegalTransition {
		t.Fatalf("answer before accept: %v", err)
	}
	_ = bobDev
}

func TestDeclineCancelTimeoutRevoke(t *testing.T) {
	svc, _, alice, bob, aliceDev, bobDev, _ := newTestService(t)
	ctx := context.Background()

	ring, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "d1")
	declined, err := svc.Decline(ctx, bob, ring.Session.ID)
	if err != nil || *declined.EndReason != EndDeclined {
		t.Fatalf("decline: %#v %v", declined, err)
	}

	ring2, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "d2")
	cancelled, err := svc.Cancel(ctx, alice, ring2.Session.ID)
	if err != nil || *cancelled.EndReason != EndCancelled {
		t.Fatalf("cancel: %#v %v", cancelled, err)
	}

	svc.now = func() time.Time { return time.Now().UTC() }
	ring3, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "d3")
	svc.now = func() time.Time { return ring3.Session.RingExpiresAt.Add(time.Second) }
	n, err := svc.ExpireRinging(ctx)
	if err != nil || n != 1 {
		t.Fatalf("expire: n=%d err=%v", n, err)
	}
	got, _ := svc.Get(ctx, alice, ring3.Session.ID)
	if got.EndReason == nil || *got.EndReason != EndTimeout {
		t.Fatalf("timeout reason: %#v", got)
	}

	ring4, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "d4")
	_, _ = svc.Accept(ctx, bob, bobDev, ring4.Session.ID)
	if err := svc.EndCallsForUser(ctx, alice); err != nil {
		t.Fatal(err)
	}
	got, _ = svc.Get(ctx, alice, ring4.Session.ID)
	if got.State != StateEnded || got.EndReason == nil || *got.EndReason != EndRevoked {
		t.Fatalf("revoked: %#v", got)
	}
}

func TestPayloadLimits(t *testing.T) {
	svc, _, alice, bob, aliceDev, bobDev, _ := newTestService(t)
	ctx := context.Background()
	ring, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "big")
	_, _ = svc.Accept(ctx, bob, bobDev, ring.Session.ID)
	huge := strings.Repeat("a", MaxSDPPChars+1)
	if _, err := svc.SetOffer(ctx, alice, ring.Session.ID, huge); err != ErrPayloadTooLarge {
		t.Fatalf("want too large, got %v", err)
	}
	_, _ = svc.SetOffer(ctx, alice, ring.Session.ID, "ok")
	bigICE := strings.Repeat("c", MaxICECandidateLen+1)
	if _, _, err := svc.AddICE(ctx, alice, ring.Session.ID, bigICE, "i1", nil, nil); err != ErrPayloadTooLarge {
		t.Fatalf("want ice too large, got %v", err)
	}
}

func TestUnauthorizedParticipant(t *testing.T) {
	svc, _, alice, bob, aliceDev, _, _ := newTestService(t)
	ctx := context.Background()
	ring, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "u1")
	outsider := uuid.New()
	if _, err := svc.Get(ctx, outsider, ring.Session.ID); err != ErrNotAuthorized {
		t.Fatalf("want not authorized, got %v", err)
	}
}
