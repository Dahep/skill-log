// Package document is the fenced usage-log block: how it is parsed,
// classified, rendered and spliced.
//
// The block the tool adopts into a skill is delimited and self-describing:
//
//	<!-- skill-log:usage-log template=<hash> hash=<hash> -->
//	## Usage log
//	...
//	<!-- /skill-log:usage-log -->
//
// `template` is the hash of the template source that rendered the block;
// `hash` is the hash of the block's content. The fence is the only
// provenance there is. Everything outside it is user-owned: the tool never
// reads, matches, rewrites or deletes a byte outside the fence — not even
// with `--force`. A skill that has usage-log text but no fence is
// `missing`; reconciling the old section is a human task.
//
// The package answers the five questions the fence makes distinguishable,
// and keeps them distinct:
//
//  1. Is there a block at all? Parse splits the text into before, block,
//     after. No fence means no block.
//  2. Was the block edited by hand? The fence's `hash` is the hash the
//     block's content had when the tool wrote it. Recompute it: a mismatch
//     means a human edited inside the fence (`edited`).
//  3. Did the template move since the block was written? The fence's
//     `template` hash is the hash of the template source that rendered it.
//     The current template's own hash is compared (`stale` vs `ok`).
//  4. Is the content the current render? The current render is the template
//     rendered for *this* skill's name and the resolved binary path, so its
//     content hash is compared too. A block that names another skill or
//     another binary is an older render (`stale`).
//  5. Is the skill vendored? A vendor stamp means skip entirely
//     (`vendored`).
//
// The shipped-default-moved question is *not* one of these: it lives in the
// state directory's seeded-from record, outside this package.
//
// Rewrite and Append are the write half: both splice through Parse's
// before/block/after split, so no byte outside the fence is touched —
// Rewrite replaces the block in place, Append adds one at the end of a
// document that has none.
package document

import (
	"encoding/hex"
)

// The FNV-1a 64-bit parameters, spelled out so the bytes that go into a
// fence are reproducible by anyone.
//
// The hash runs over bytes, not code points: the fence is compared across
// machines and releases, and a byte-level hash cannot be moved by an
// encoding detail. The multiplication is the 64-bit wrap-around arithmetic
// FNV specifies.
//
// It is a non-cryptographic hash: its job is drift detection on text the
// tool itself wrote, not tamper-proofing against an adversary. The output is
// 16 lowercase hex digits, and it is the spelling that goes into the fence
// (`hash=...`) and into the seeded-from record.
const (
	fnvOffsetBasis uint64 = 0xcbf29ce484222325
	fnvPrime       uint64 = 0x100000001b3
)

// Hash is the FNV-1a 64-bit hash of the text's bytes, as 16 lowercase hex
// digits.
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
