"""The stable document hash.

The fence carries two hashes — the template's and the block content's —
and the seeded-from record in the state directory carries a third. All
three are persisted in user files and compared across releases, so the
hash must be *stable across releases*: the same bytes hash the same way
forever. A stdlib hash whose output may change between releases would
silently mark every adopted block `edited` after an upgrade, so it is
not used.

The algorithm is FNV-1a, 64-bit, over the text's bytes:

- offset basis `0xcbf29ce484222325`
- prime `0x100000001b3`
- each byte: `h = (h XOR byte) * prime` modulo 2^64

FNV-1a 64-bit is self-contained and deterministic, and it is spelled out
above so the bytes that go into a fence are reproducible by anyone. It
is a non-cryptographic hash: its job is drift detection on text the tool
itself wrote, not tamper-proofing against an adversary. The output is
16 lowercase hex digits, and it is the spelling that goes into the
fence (`hash=...`) and into the seeded-from record.
"""


def fnv1a64_hex(text: String) -> String:
    """The FNV-1a 64-bit hash of `text`'s bytes, as 16 lowercase hex
    digits.

    The hash runs over bytes, not code points: the fence is compared
    across machines and releases, and a byte-level hash cannot be moved
    by an encoding detail. The multiplication is the 64-bit wrap-around
    arithmetic FNV specifies.
    """
    var h: UInt64 = 0xcbf29ce484222325
    var base = text.unsafe_ptr()
    var n = text.byte_length()
    for i in range(n):
        h = (h ^ UInt64(base[unsafe_offset=i])) * 0x100000001b3
    return hex64(h)


def hex64(value: UInt64) -> String:
    """`value` as exactly 16 lowercase hex digits."""
    var digits = "0123456789abcdef"
    var out = String("")
    for shift in [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0]:
        var nibble = Int((value >> UInt64(shift)) & 0xF)
        var i = 0
        for c in digits.codepoints():
            if i == nibble:
                out += String(c)
                break
            i += 1
    return out
