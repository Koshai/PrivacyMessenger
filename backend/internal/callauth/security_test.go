package callauth

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/google/uuid"
)

type fakeCalls struct {
	view CallView
	err  error
}

func (f fakeCalls) CallFor(context.Context, uuid.UUID, uuid.UUID) (CallView, error) {
	if f.err != nil {
		return CallView{}, f.err
	}
	return f.view, nil
}

type fakeRevoke struct{ revoked map[uuid.UUID]bool }

func (f fakeRevoke) DeviceRevoked(_ context.Context, _, device uuid.UUID) (bool, error) {
	return f.revoked[device], nil
}

type party struct {
	user, device uuid.UUID
	pub          ed25519.PublicKey
	priv         ed25519.PrivateKey
	mls          []byte
	nonce        []byte
	dtls         []byte
}

func newParty(t *testing.T) party {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	mls := bytesRepeat(FPSize, 0x11)
	dtls := bytesRepeat(FPSize, 0x22)
	nonce, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	return party{user: uuid.New(), device: uuid.New(), pub: pub, priv: priv, mls: mls, nonce: nonce, dtls: dtls}
}

func bytesRepeat(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func setup(t *testing.T) (*Service, fakeCalls, party, party, CallView) {
	t.Helper()
	alice, bob := newParty(t), newParty(t)
	bob.mls = bytesRepeat(FPSize, 0x33)
	bob.dtls = bytesRepeat(FPSize, 0x44)
	now := time.Now().UTC()
	callee := bob.device
	view := CallView{
		ID: uuid.New(), CallerUser: alice.user, CalleeUser: bob.user,
		CallerDevice: alice.device, CalleeDevice: &callee, MediaAudio: true,
		AcceptedAt: &now, CreatedAt: now,
	}
	store := NewMemoryStore()
	svc := NewService(store, fakeCalls{view: view}, fakeRevoke{revoked: map[uuid.UUID]bool{}})
	if err := svc.RegisterKey(context.Background(), alice.user, alice.device, alice.pub); err != nil {
		t.Fatal(err)
	}
	if err := svc.RegisterKey(context.Background(), bob.user, bob.device, bob.pub); err != nil {
		t.Fatal(err)
	}
	return svc, fakeCalls{view: view}, alice, bob, view
}

func helloInput(call CallView, p party, role byte) SubmitInput {
	msg, err := (Hello{CallID: call.ID, UserID: p.user, DeviceID: p.device, Role: role, Nonce: p.nonce, CallKey: p.pub, MLS: p.mls}).Bytes()
	if err != nil {
		panic(err)
	}
	sig, err := Sign(p.priv, msg)
	if err != nil {
		panic(err)
	}
	return SubmitInput{
		CallID: call.ID, ActorUser: p.user, ActorDevice: p.device, Kind: KindHello,
		ClientAuthID: uuid.NewString(), Nonce: p.nonce, CallKey: p.pub, MLS: p.mls, Signature: sig,
	}
}

func confirmInput(call CallView, signer party, tr Transcript, clientID string) SubmitInput {
	msg, err := tr.Bytes()
	if err != nil {
		panic(err)
	}
	sig, err := Sign(signer.priv, msg)
	if err != nil {
		panic(err)
	}
	local, remote := tr.CallerDTLS, tr.CalleeDTLS
	if signer.user == call.CalleeUser {
		local, remote = tr.CalleeDTLS, tr.CallerDTLS
	}
	return SubmitInput{
		CallID: call.ID, ActorUser: signer.user, ActorDevice: signer.device, Kind: KindConfirm,
		ClientAuthID: clientID, Nonce: signer.nonce, CallKey: signer.pub, MLS: signer.mls,
		DTLSLocal: local, DTLSRemote: remote, Signature: sig,
	}
}

func fullTranscript(call CallView, alice, bob party) Transcript {
	return Transcript{
		CallID: call.ID, CallerUser: alice.user, CalleeUser: bob.user,
		CallerDevice: alice.device, CalleeDevice: bob.device, MediaAudio: true,
		CallerNonce: alice.nonce, CalleeNonce: bob.nonce,
		CallerDTLS: alice.dtls, CalleeDTLS: bob.dtls,
		CallerMLS: alice.mls, CalleeMLS: bob.mls,
		CallerCallKey: alice.pub, CalleeCallKey: bob.pub,
	}
}

func TestSuccessfulAuthenticatedCall(t *testing.T) {
	svc, _, alice, bob, call := setup(t)
	ctx := context.Background()
	if _, err := svc.Submit(ctx, helloInput(call, alice, RoleCaller)); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Submit(ctx, helloInput(call, bob, RoleCallee)); err != nil {
		t.Fatal(err)
	}
	tr := fullTranscript(call, alice, bob)
	if _, err := svc.Submit(ctx, confirmInput(call, alice, tr, "a-confirm")); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Submit(ctx, confirmInput(call, bob, tr, "b-confirm")); err != nil {
		t.Fatal(err)
	}
	if err := VerifyPeerConfirm(bob.pub, bob.dtls, tr, false, confirmInput(call, bob, tr, "b-confirm").Signature); err != nil {
		t.Fatal(err)
	}
	if err := VerifyPeerConfirm(alice.pub, alice.dtls, tr, true, confirmInput(call, alice, tr, "a-confirm").Signature); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsWrongPeerKeyForgeryReplayAndMutations(t *testing.T) {
	svc, _, alice, bob, call := setup(t)
	ctx := context.Background()
	_, _ = svc.Submit(ctx, helloInput(call, alice, RoleCaller))
	_, _ = svc.Submit(ctx, helloInput(call, bob, RoleCallee))
	tr := fullTranscript(call, alice, bob)

	other := newParty(t)
	bad := confirmInput(call, alice, tr, "forged")
	bad.ActorUser = bob.user
	bad.ActorDevice = bob.device
	bad.CallKey = other.pub
	if _, err := svc.Submit(ctx, bad); err == nil {
		t.Fatal("expected wrong peer key rejection")
	}

	forged := confirmInput(call, bob, tr, "sig")
	forged.Signature = bytesRepeat(SigSize, 9)
	if _, err := svc.Submit(ctx, forged); err == nil {
		t.Fatal("expected forged signature rejection")
	}

	ok := confirmInput(call, bob, tr, "replay-id")
	if _, err := svc.Submit(ctx, ok); err != nil {
		t.Fatal(err)
	}
	otherCall := call
	otherCall.ID = uuid.New()
	replay := ok
	replay.CallID = otherCall.ID
	svc2 := NewService(NewMemoryStore(), fakeCalls{view: otherCall}, fakeRevoke{})
	_ = svc2.RegisterKey(ctx, bob.user, bob.device, bob.pub)
	if _, err := svc2.Submit(ctx, replay); err == nil {
		t.Fatal("expected replay onto another call to fail signature or membership")
	}

	swapped := tr
	swapped.CallerUser, swapped.CalleeUser = tr.CalleeUser, tr.CallerUser
	if err := VerifyPeerConfirm(bob.pub, bob.dtls, swapped, false, ok.Signature); err == nil {
		t.Fatal("expected swapped roles to fail")
	}
	changedID := tr
	changedID.CallID = uuid.New()
	if err := VerifyPeerConfirm(bob.pub, bob.dtls, changedID, false, ok.Signature); err == nil {
		t.Fatal("expected modified call id to fail")
	}
	changedDTLS := tr
	changedDTLS.CalleeDTLS = bytesRepeat(FPSize, 0x99)
	if err := VerifyPeerConfirm(bob.pub, changedDTLS.CalleeDTLS, tr, false, ok.Signature); err == nil {
		t.Fatal("expected observed dtls mismatch to fail")
	}
	if err := VerifyPeerConfirm(other.pub, bob.dtls, tr, false, ok.Signature); err == nil {
		t.Fatal("expected unexpected key to fail")
	}
}

func TestDeviceReplacementRevocationAndDuplicates(t *testing.T) {
	alice, bob := newParty(t), newParty(t)
	bob.mls = bytesRepeat(FPSize, 0x33)
	now := time.Now().UTC()
	callee := bob.device
	view := CallView{
		ID: uuid.New(), CallerUser: alice.user, CalleeUser: bob.user,
		CallerDevice: alice.device, CalleeDevice: &callee, MediaAudio: true,
		AcceptedAt: &now, CreatedAt: now,
	}
	store := NewMemoryStore()
	rev := fakeRevoke{revoked: map[uuid.UUID]bool{}}
	svc := NewService(store, fakeCalls{view: view}, rev)
	ctx := context.Background()
	_ = svc.RegisterKey(ctx, alice.user, alice.device, alice.pub)
	_ = svc.RegisterKey(ctx, bob.user, bob.device, bob.pub)

	replacement := newParty(t)
	replacement.user = bob.user
	repView := view
	repDev := replacement.device
	repView.CalleeDevice = &repDev
	if _, err := NewService(store, fakeCalls{view: repView}, rev).Submit(ctx, helloInput(view, bob, RoleCallee)); err == nil {
		t.Fatal("expected device replacement during negotiation to fail")
	}

	rev.revoked[bob.device] = true
	if _, err := svc.Submit(ctx, helloInput(view, bob, RoleCallee)); err != ErrRevoked {
		t.Fatalf("revoked: %v", err)
	}
	rev.revoked[bob.device] = false

	first := helloInput(view, alice, RoleCaller)
	if _, err := svc.Submit(ctx, first); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Submit(ctx, first); err != nil {
		t.Fatal("identical retry should be idempotent")
	}
	mutated := first
	mutated.Nonce = bytesRepeat(NonceSize, 7)
	msg, _ := (Hello{CallID: view.ID, UserID: alice.user, DeviceID: alice.device, Role: RoleCaller, Nonce: mutated.Nonce, CallKey: alice.pub, MLS: alice.mls}).Bytes()
	mutated.Signature, _ = Sign(alice.priv, msg)
	if _, err := svc.Submit(ctx, mutated); err != ErrReplay {
		t.Fatalf("conflicting duplicate: %v", err)
	}

	view.Ended = true
	ended := NewService(store, fakeCalls{view: view}, rev)
	bobHello := helloInput(view, bob, RoleCallee)
	if _, err := ended.Submit(ctx, bobHello); err == nil {
		t.Fatal("expected ended call to reject auth")
	}
}

func TestVectorEd25519(t *testing.T) {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	callID := uuid.MustParse("01010101-0101-4101-8101-010101010101")
	msg, err := (Hello{
		CallID: callID, UserID: callID, DeviceID: callID, Role: RoleCaller,
		Nonce: bytesRepeat(32, 9), CallKey: pub, MLS: bytesRepeat(32, 4),
	}).Bytes()
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, msg)
	t.Logf("pub=%x", pub)
	t.Logf("sig=%x", sig)
	t.Logf("msglen=%d", len(msg))
}

func TestConcurrentConfirms(t *testing.T) {
	svc, _, alice, bob, call := setup(t)
	ctx := context.Background()
	_, _ = svc.Submit(ctx, helloInput(call, alice, RoleCaller))
	_, _ = svc.Submit(ctx, helloInput(call, bob, RoleCallee))
	tr := fullTranscript(call, alice, bob)
	errCh := make(chan error, 2)
	go func() { _, err := svc.Submit(ctx, confirmInput(call, alice, tr, "c-a")); errCh <- err }()
	go func() { _, err := svc.Submit(ctx, confirmInput(call, bob, tr, "c-b")); errCh <- err }()
	for i := 0; i < 2; i++ {
		if err := <-errCh; err != nil {
			t.Fatal(err)
		}
	}
}
