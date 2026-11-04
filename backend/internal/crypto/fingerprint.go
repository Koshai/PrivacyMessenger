package crypto

import (
	"crypto/sha256"
	"encoding/hex"
)

func FingerprintHex(publicKey []byte) string {
	sum := sha256.Sum256(publicKey)
	return hex.EncodeToString(sum[:])
}
