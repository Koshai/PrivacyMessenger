package crypto_test

import (
	"context"
	"sync"
	"testing"

	"example.com/private-messenger/backend/internal/crypto"

	"github.com/google/uuid"
)

type fakeFriends struct {
	ok bool
}

func (f fakeFriends) AreAcceptedFriends(context.Context, uuid.UUID, uuid.UUID) (bool, error) {
	return f.ok, nil
}

type fakeDevices map[uuid.UUID]uuid.UUID

func (d fakeDevices) DeviceBelongsToUser(_ context.Context, deviceID, userID uuid.UUID) (bool, error) {
	owner, ok := d[deviceID]
	return ok && owner == userID, nil
}

func TestRegisterIdentityOwnershipAndContinuity(t *testing.T) {
	store := crypto.NewMemoryStore()
	alice := uuid.New()
	device := uuid.New()
	svc := crypto.NewService(store, fakeFriends{ok: true}, fakeDevices{device: alice})

	pub := []byte{1, 2, 3, 4}
	id, created, err := svc.RegisterIdentity(context.Background(), alice, device, pub)
	if err != nil || !created {
		t.Fatalf("register: created=%v err=%v", created, err)
	}
	if id.FingerprintHex == "" {
		t.Fatal("expected fingerprint")
	}

	_, _, err = svc.RegisterIdentity(context.Background(), alice, device, []byte{9, 9})
	if err != crypto.ErrIdentityMismatch {
		t.Fatalf("want mismatch, got %v", err)
	}

	eve := uuid.New()
	_, _, err = svc.RegisterIdentity(context.Background(), eve, device, pub)
	if err != crypto.ErrNotAuthorized {
		t.Fatalf("forged ownership: %v", err)
	}
}

func TestClaimKeyPackageOneTimeAndConcurrent(t *testing.T) {
	store := crypto.NewMemoryStore()
	alice, bob := uuid.New(), uuid.New()
	aliceDev := uuid.New()
	devices := fakeDevices{aliceDev: alice}
	svc := crypto.NewService(store, fakeFriends{ok: true}, devices)

	if _, _, err := svc.RegisterIdentity(context.Background(), alice, aliceDev, []byte("alice-pub")); err != nil {
		t.Fatal(err)
	}
	pkgs := make([][]byte, 3)
	for i := range pkgs {
		pkgs[i] = []byte{byte(i + 1)}
	}
	if err := svc.UploadKeyPackages(context.Background(), alice, aliceDev, pkgs, 0); err != nil {
		t.Fatal(err)
	}

	first, _, err := svc.ClaimKeyPackage(context.Background(), bob, alice)
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := svc.ClaimKeyPackage(context.Background(), bob, alice)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == second.ID {
		t.Fatal("duplicate consumption")
	}

	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, err := svc.ClaimKeyPackage(context.Background(), bob, alice)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)

	success := 0
	for err := range errs {
		if err == nil {
			success++
		} else if err != crypto.ErrNoKeyPackage {
			t.Fatalf("unexpected: %v", err)
		}
	}
	if success != 1 {
		t.Fatalf("expected 1 remaining package claimed, got %d", success)
	}
}

func TestRevokedDeviceBlocksUpload(t *testing.T) {
	store := crypto.NewMemoryStore()
	alice := uuid.New()
	device := uuid.New()
	svc := crypto.NewService(store, fakeFriends{ok: true}, fakeDevices{device: alice})
	if _, _, err := svc.RegisterIdentity(context.Background(), alice, device, []byte("pk")); err != nil {
		t.Fatal(err)
	}
	if err := svc.RevokeDevice(context.Background(), alice, device); err != nil {
		t.Fatal(err)
	}
	err := svc.UploadKeyPackages(context.Background(), alice, device, [][]byte{[]byte("kp")}, 0)
	if err != crypto.ErrIdentityRevoked {
		t.Fatalf("want revoked, got %v", err)
	}
}

func TestUnauthorizedPeerCannotClaim(t *testing.T) {
	store := crypto.NewMemoryStore()
	alice, bob := uuid.New(), uuid.New()
	aliceDev := uuid.New()
	svc := crypto.NewService(store, fakeFriends{ok: false}, fakeDevices{aliceDev: alice})
	if _, _, err := svc.RegisterIdentity(context.Background(), alice, aliceDev, []byte("pk")); err != nil {
		t.Fatal(err)
	}
	_ = svc.UploadKeyPackages(context.Background(), alice, aliceDev, [][]byte{[]byte("kp")}, 0)
	_, _, err := svc.ClaimKeyPackage(context.Background(), bob, alice)
	if err != crypto.ErrNotAuthorized {
		t.Fatalf("got %v", err)
	}
}
