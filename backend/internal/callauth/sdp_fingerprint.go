package callauth

import (
	"encoding/hex"
	"strings"
)

// SDPFingerprint extracts the negotiated SHA-256 DTLS fingerprint from SDP.
// WebRTC checks this value against the certificate presented on the DTLS association.
func SDPFingerprint(sdp string) ([]byte, error) {
	const marker = "a=fingerprint:sha-256 "
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(strings.ToLower(line), marker) {
			continue
		}
		hexPart := strings.ReplaceAll(line[len(marker):], ":", "")
		raw, err := hex.DecodeString(hexPart)
		if err != nil || len(raw) != FPSize {
			return nil, ErrInvalid
		}
		return raw, nil
	}
	return nil, ErrInvalid
}
