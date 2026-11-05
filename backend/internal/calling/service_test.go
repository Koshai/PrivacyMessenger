package calling

import (
	"context"
	"strings"
	"sync"
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

func newTestService(t *testing.T) (*Service, uuid.UUID, uuid.UUID, uuid.UUID, uuid.UUID) {
	t.Helper()
	alice, bob := uuid.New(), uuid.New()
	aliceDev, bobDev := uuid.New(), uuid.New()
	store := NewMemoryStore()
	friends := &memFriends{ok: map[[2]uuid.UUID]bool{{alice, bob}: true}}
	blocks := &memBlocks{blocked: map[[2]uuid.UUID]bool{}}
	svc := NewService(store, friends, blocks).WithNotifier(&memNotify{})
	return svc, alice, bob, aliceDev, bobDev
}

func TestAnswerDoesNotMarkConnected(t *testing.T) {
	svc, alice, bob, aliceDev, bobDev := newTestService(t)
	ctx := context.Background()
	res, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "c1")
	_, _ = svc.Accept(ctx, bob, bobDev, res.Session.ID)
	_, _ = svc.SetOffer(ctx, alice, res.Session.ID, "offer")
	ans, err := svc.SetAnswer(ctx, bob, res.Session.ID, "answer")
	if err != nil {
		t.Fatal(err)
	}
	if ans.State != StateAccepted {
		t.Fatalf("answer must leave state accepted, got %s", ans.State)
	}
	conn, err := svc.MarkConnected(ctx, alice, res.Session.ID)
	if err != nil || conn.State != StateConnected {
		t.Fatalf("mark connected: %#v %v", conn, err)
	}
}

func TestIdempotentInitiateValidatesParams(t *testing.T) {
	svc, alice, bob, aliceDev, _ := newTestService(t)
	ctx := context.Background()
	_, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "idem")
	if err != nil {
		t.Fatal(err)
	}
	otherDev := uuid.New()
	if _, err := svc.Initiate(ctx, alice, otherDev, bob, MediaAudio, "idem"); err != ErrReplay {
		t.Fatalf("device mismatch want replay, got %v", err)
	}
	if _, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaVideo, "idem"); err != ErrReplay {
		t.Fatalf("media mismatch want replay, got %v", err)
	}
	stranger := uuid.New()
	if _, err := svc.Initiate(ctx, alice, aliceDev, stranger, MediaAudio, "idem"); err != ErrReplay {
		t.Fatalf("callee mismatch want replay, got %v", err)
	}
}

func TestDeviceBindingOnAccept(t *testing.T) {
	svc, alice, bob, aliceDev, bobDev := newTestService(t)
	ctx := context.Background()
	res, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "dev")
	_, err := svc.Accept(ctx, bob, bobDev, res.Session.ID)
	if err != nil {
		t.Fatal(err)
	}
	other := uuid.New()
	if _, err := svc.Accept(ctx, bob, other, res.Session.ID); err != ErrDeviceConflict {
		t.Fatalf("want device conflict, got %v", err)
	}
	again, err := svc.Accept(ctx, bob, bobDev, res.Session.ID)
	if err != nil || again.State != StateAccepted {
		t.Fatalf("same device idempotent accept failed: %v", err)
	}
}

func TestPrivacyErrorsUnified(t *testing.T) {
	svc, alice, _, aliceDev, _ := newTestService(t)
	stranger := uuid.New()
	_, err := svc.Initiate(context.Background(), alice, aliceDev, stranger, MediaAudio, "p1")
	if err != ErrNotAvailable {
		t.Fatalf("nonfriend: %v", err)
	}
	a, b := uuid.New(), uuid.New()
	adev := uuid.New()
	svc2 := NewService(NewMemoryStore(), &memFriends{ok: map[[2]uuid.UUID]bool{{a, b}: true}}, &memBlocks{blocked: map[[2]uuid.UUID]bool{{a, b}: true}})
	_, err = svc2.Initiate(context.Background(), a, adev, b, MediaAudio, "p2")
	if err != ErrNotAvailable {
		t.Fatalf("blocked: %v", err)
	}
}

func TestHangupClearsSignalingAtomically(t *testing.T) {
	svc, alice, bob, aliceDev, bobDev := newTestService(t)
	ctx := context.Background()
	res, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "clr")
	_, _ = svc.Accept(ctx, bob, bobDev, res.Session.ID)
	_, _ = svc.SetOffer(ctx, alice, res.Session.ID, "o")
	_, _ = svc.SetAnswer(ctx, bob, res.Session.ID, "a")
	_, _, _ = svc.AddICE(ctx, alice, res.Session.ID, "cand", "i1", nil, nil)
	ended, err := svc.HangUp(ctx, alice, res.Session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if ended.SDPOffer != nil || ended.SDPAnswer != nil {
		t.Fatal("sdp must be nil")
	}
	left, err := svc.ListICE(ctx, alice, res.Session.ID, 0, 10)
	if err != nil || len(left) != 0 {
		t.Fatalf("ice must be empty: %#v %v", left, err)
	}
}

func TestConcurrentBusyMemory(t *testing.T) {
	svc, alice, bob, aliceDev, _ := newTestService(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, uuid.NewString())
			errs <- err
		}(i)
	}
	wg.Wait()
	close(errs)
	ok, busy := 0, 0
	for err := range errs {
		switch err {
		case nil:
			ok++
		case ErrBusy:
			busy++
		default:
			t.Fatalf("unexpected %v", err)
		}
	}
	if ok != 1 || busy != 19 {
		t.Fatalf("want 1 ok 19 busy, got ok=%d busy=%d", ok, busy)
	}
}

func TestPayloadAndTimeout(t *testing.T) {
	svc, alice, bob, aliceDev, bobDev := newTestService(t)
	ctx := context.Background()
	ring, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "big")
	_, _ = svc.Accept(ctx, bob, bobDev, ring.Session.ID)
	if _, err := svc.SetOffer(ctx, alice, ring.Session.ID, strings.Repeat("a", MaxSDPPChars+1)); err != ErrPayloadTooLarge {
		t.Fatalf("sdp: %v", err)
	}
	_, _ = svc.HangUp(ctx, alice, ring.Session.ID)

	ring2, _ := svc.Initiate(ctx, alice, aliceDev, bob, MediaAudio, "to")
	svc.now = func() time.Time { return ring2.Session.RingExpiresAt.Add(time.Second) }
	n, err := svc.ExpireRinging(ctx)
	if err != nil || n != 1 {
		t.Fatalf("expire n=%d err=%v", n, err)
	}
}
