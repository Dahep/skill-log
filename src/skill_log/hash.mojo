"""The one hash the tool uses."""


def fnv1a64_hex(text: String) -> String:
    """The FNV-1a 64-bit hash of `text`'s bytes, as 16 lowercase hex"""
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
