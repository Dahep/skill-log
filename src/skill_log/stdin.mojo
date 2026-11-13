"""Reading stdin without blocking a terminal."""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import alloc

from skill_log.ffi import dl_sym

comptime STDIN_SIZE = 65536


def stdin_is_tty() -> Bool:
    """True when standard input is a terminal."""
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var isatty = dl_sym[def(Int) thin abi("C") -> Int](lib, "isatty")
        return isatty(Int(0)) != 0
    except:
        return True


def read_stdin_line() -> String:
    """One line from standard input, without its newline.

    A hook pipes one line into `add --problem -`, so this reads exactly one
    line and never blocks on a terminal.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var read = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](lib, "read")
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
    """`text` up to its first newline, with the newline removed."""
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
