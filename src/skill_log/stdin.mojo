"""Reading stdin without blocking a terminal."""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import alloc

from skill_log.ffi import dl_sym

# How much of standard input one read takes. A problem's own text is one
# line, so this is generous; anything longer is truncated at the first
# line, which is the invariant that matters.
comptime STDIN_SIZE = 65536


def stdin_is_tty() -> Bool:
    """True when standard input is a terminal.

    A hook that reads the problem text from stdin must not block on an
    interactive terminal, so the caller asks this first and refuses
    instead of waiting.

    False when the answer cannot be found: the refusal is the safe
    side of that ambiguity, because a terminal that is mistaken for a
    pipe would make the command hang.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var isatty = dl_sym[def(Int) thin abi("C") -> Int](lib, "isatty")
        return isatty(Int(0)) != 0
    except:
        return True


def read_stdin_line() -> String:
    """One line from standard input, without its newline.

    An empty string when standard input carries nothing, or when it
    cannot be read. The bytes are decoded up to the count actually read:
    the buffer carries one spare byte for the terminator, so the span is
    bounded by the allocation even when the input filled it.

    Reads repeat until the first newline or the buffer is full. One
    `read` is allowed to return a short count — a producer that writes
    `first`, pauses, then writes `second\\n` is still one line — so a
    single call would silently keep only the first part of the text.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        # The buffer is passed as an address, so the call can be resumed
        # at an offset without a second pointer type.
        var read = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](lib, "read")
        # One spare byte: the terminator goes at `count`, which is inside
        # the allocation even when the read filled the whole buffer.
        var buffer = alloc[c_char](STDIN_SIZE + 1)
        var count = 0
        while count < STDIN_SIZE:
            var n = read(Int(0), Int(buffer) + count, Int(STDIN_SIZE - count))
            if n <= 0:
                break
            var saw_newline = False
            for i in range(count, count + n):
                if Int(buffer[i]) == 10:
                    saw_newline = True
                    break
            count += n
            if saw_newline:
                break
        if count <= 0:
            return ""
        buffer[count] = 0
        var raw = String(
            StringSlice(unsafe_from_utf8=CStringSpan(unsafe_from_ptr=buffer))
        )
        return trim_to_line(raw)
    except:
        return ""


def trim_to_line(text: String) -> String:
    """`text` up to its first newline, with the newline removed.

    A carriage return before it goes too, so a CRLF pipe yields the
    same text as a LF one.
    """
    var cut = text.find("\n")
    var line = text
    if cut != -1:
        var part = text[byte=0:cut]
        var without_newline = String(part)
        line = without_newline
    if line.endswith("\r"):
        var shorter = line.byte_length() - 1
        var without = line[byte=0:shorter]
        var trimmed = String(without)
        line = trimmed
    return line
