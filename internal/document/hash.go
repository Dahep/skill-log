// Package document parses, renders, classifies and splices the fenced usage-log block.
package document

import (
	"encoding/hex"
)

// The FNV-1a 64-bit parameters. The hash runs over bytes, not code points.
const (
	fnvOffsetBasis uint64 = 0xcbf29ce484222325
	fnvPrime       uint64 = 0x100000001b3
)

// Hash is the FNV-1a 64-bit hash of the text's bytes, as 16 lowercase hex digits.
func Hash(text string) string {
	h := fnvOffsetBasis
	for i := 0; i < len(text); i++ {
		h = (h ^ uint64(text[i])) * fnvPrime
	}
	var out [8]byte
	for i := 0; i < 8; i++ {
		out[7-i] = byte(h >> (8 * i))
	}
	return hex.EncodeToString(out[:])
}
