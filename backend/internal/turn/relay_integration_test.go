package turn

import (
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/pion/webrtc/v4"
)

// TestRelayOnlyDataChannel proves two peers exchange bytes through coturn.
// An SDP offer alone is not treated as success: the nominated pair must be
// relay/relay and a data channel message must arrive.
func TestRelayOnlyDataChannel(t *testing.T) {
	if os.Getenv("TURN_RELAY_TEST") != "1" {
		t.Skip("TURN_RELAY_TEST=1 not set")
	}
	secret := os.Getenv("TURN_TEST_SECRET")
	if secret == "" {
		secret = "local-dev-turn-secret"
	}
	turnURL := os.Getenv("TURN_TEST_URL")
	if turnURL == "" {
		turnURL = "turn:127.0.0.1:3478?transport=udp"
	}

	cfg := Config{
		SharedSecret: secret,
		TURNURLs:     []string{turnURL},
		TTL:          5 * time.Minute,
		Realm:        "privacy.test",
	}
	leftCred, err := Issue(cfg, uuid.New(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	rightCred, err := Issue(cfg, uuid.New(), time.Now())
	if err != nil {
		t.Fatal(err)
	}

	left, err := webrtc.NewPeerConnection(peerConfig(leftCred, turnURL))
	if err != nil {
		t.Fatal(err)
	}
	right, err := webrtc.NewPeerConnection(peerConfig(rightCred, turnURL))
	if err != nil {
		t.Fatal(err)
	}
	defer left.Close()
	defer right.Close()

	got := make(chan string, 1)
	right.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			got <- string(msg.Data)
		})
	})
	dc, err := left.CreateDataChannel("probe", nil)
	if err != nil {
		t.Fatal(err)
	}

	if err := exchangeSession(left, right); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(25 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for relay ICE connected")
		}
		if left.ICEConnectionState() == webrtc.ICEConnectionStateConnected ||
			left.ICEConnectionState() == webrtc.ICEConnectionStateCompleted {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !hasNominatedRelayPair(t, left) {
		t.Fatal("nominated candidate pair was not relay/relay")
	}

	open := make(chan struct{})
	dc.OnOpen(func() { close(open) })
	select {
	case <-open:
	case <-time.After(10 * time.Second):
		t.Fatal("data channel did not open")
	}
	if err := dc.SendText("relay-ok"); err != nil {
		t.Fatal(err)
	}
	select {
	case msg := <-got:
		if msg != "relay-ok" {
			t.Fatalf("payload %q", msg)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("data channel payload not received")
	}

	if err := left.Close(); err != nil {
		t.Fatal(err)
	}
	if err := right.Close(); err != nil {
		t.Fatal(err)
	}
}

func peerConfig(cred Credentials, turnURL string) webrtc.Configuration {
	return webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{{
			URLs:       []string{turnURL},
			Username:   cred.Username,
			Credential: cred.Credential,
		}},
		ICETransportPolicy: webrtc.ICETransportPolicyRelay,
	}
}

func exchangeSession(left, right *webrtc.PeerConnection) error {
	leftCands := make(chan webrtc.ICECandidateInit, 32)
	rightCands := make(chan webrtc.ICECandidateInit, 32)
	left.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		leftCands <- c.ToJSON()
	})
	right.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		rightCands <- c.ToJSON()
	})

	offer, err := left.CreateOffer(nil)
	if err != nil {
		return err
	}
	if err := left.SetLocalDescription(offer); err != nil {
		return err
	}
	if err := right.SetRemoteDescription(offer); err != nil {
		return err
	}
	answer, err := right.CreateAnswer(nil)
	if err != nil {
		return err
	}
	if err := right.SetLocalDescription(answer); err != nil {
		return err
	}
	if err := left.SetRemoteDescription(answer); err != nil {
		return err
	}

	deadline := time.After(20 * time.Second)
	leftOpen, rightOpen := true, true
	for leftOpen || rightOpen {
		select {
		case c := <-leftCands:
			if err := right.AddICECandidate(c); err != nil {
				return err
			}
		case c := <-rightCands:
			if err := left.AddICECandidate(c); err != nil {
				return err
			}
		case <-time.After(300 * time.Millisecond):
			if left.ICEGatheringState() == webrtc.ICEGatheringStateComplete {
				leftOpen = false
			}
			if right.ICEGatheringState() == webrtc.ICEGatheringStateComplete {
				rightOpen = false
			}
		case <-deadline:
			return fmt.Errorf("ICE gathering timed out")
		}
	}
	return nil
}

func hasNominatedRelayPair(t *testing.T, pc *webrtc.PeerConnection) bool {
	t.Helper()
	stats := pc.GetStats()
	types := map[string]webrtc.ICECandidateType{}
	for _, s := range stats {
		if c, ok := s.(webrtc.ICECandidateStats); ok {
			types[c.ID] = c.CandidateType
		}
	}
	for _, s := range stats {
		pair, ok := s.(webrtc.ICECandidatePairStats)
		if !ok || !pair.Nominated {
			continue
		}
		if types[pair.LocalCandidateID] == webrtc.ICECandidateTypeRelay &&
			types[pair.RemoteCandidateID] == webrtc.ICECandidateTypeRelay {
			return true
		}
		t.Logf("nominated pair local=%s remote=%s", types[pair.LocalCandidateID], types[pair.RemoteCandidateID])
	}
	return false
}

// Ensure docker is referenced so operators can see why a manual run failed.
var _ = exec.LookPath
