package callauth

import (
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/pion/webrtc/v4"
)

func TestRealWebRTCFingerprintBinding(t *testing.T) {
	left, right := newPC(t), newPC(t)
	defer left.Close()
	defer right.Close()
	if err := exchangeHost(left, right); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for left.ConnectionState() != webrtc.PeerConnectionStateConnected && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if left.ConnectionState() != webrtc.PeerConnectionStateConnected {
		t.Fatal("peers did not connect")
	}
	callerFP, err := SDPFingerprint(left.LocalDescription().SDP)
	if err != nil {
		t.Fatal(err)
	}
	calleeFP, err := SDPFingerprint(right.LocalDescription().SDP)
	if err != nil {
		t.Fatal(err)
	}
	observedRemote, err := SDPFingerprint(left.RemoteDescription().SDP)
	if err != nil {
		t.Fatal(err)
	}
	if !bytesEqual(observedRemote, calleeFP) {
		t.Fatal("remote SDP fingerprint is not the peer certificate fingerprint")
	}

	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	tr := Transcript{
		CallID: uuid.New(), CallerUser: uuid.New(), CalleeUser: uuid.New(),
		CallerDevice: uuid.New(), CalleeDevice: uuid.New(), MediaAudio: true,
		CallerNonce: bytesRepeat(32, 1), CalleeNonce: bytesRepeat(32, 2),
		CallerDTLS: callerFP, CalleeDTLS: calleeFP,
		CallerMLS: bytesRepeat(32, 3), CalleeMLS: bytesRepeat(32, 4),
		CallerCallKey: pub, CalleeCallKey: pub,
	}
	msg, err := tr.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, msg)
	if err := VerifyPeerConfirm(pub, calleeFP, tr, false, sig); err != nil {
		t.Fatal(err)
	}
	tampered := append([]byte(nil), calleeFP...)
	tampered[0] ^= 0xff
	if err := VerifyPeerConfirm(pub, tampered, tr, false, sig); err == nil {
		t.Fatal("altered DTLS fingerprint must fail closed")
	}
}

func newPC(t *testing.T) *webrtc.PeerConnection {
	t.Helper()
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio); err != nil {
		t.Fatal(err)
	}
	return pc
}

func exchangeHost(left, right *webrtc.PeerConnection) error {
	left.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			_ = right.AddICECandidate(c.ToJSON())
		}
	})
	right.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			_ = left.AddICECandidate(c.ToJSON())
		}
	})
	offer, err := left.CreateOffer(nil)
	if err != nil {
		return err
	}
	if err := left.SetLocalDescription(offer); err != nil {
		return err
	}
	<-webrtc.GatheringCompletePromise(left)
	if err := right.SetRemoteDescription(*left.LocalDescription()); err != nil {
		return err
	}
	answer, err := right.CreateAnswer(nil)
	if err != nil {
		return err
	}
	if err := right.SetLocalDescription(answer); err != nil {
		return err
	}
	<-webrtc.GatheringCompletePromise(right)
	return left.SetRemoteDescription(*right.LocalDescription())
}
