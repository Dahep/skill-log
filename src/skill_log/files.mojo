"""Reading and atomically replacing a small text file.

A report file is committed with a change, so a half-written one — a
crash between `truncate` and the last marker — would be a corrupted
artifact in the tree. The write goes to a fresh sibling temporary file
and is then renamed over the target: `rename(2)` inside one directory is
atomic, so a reader sees either the old report or the new one, never a
mixture.

The temporary file is created **exclusively** under an unpredictable
name (`<target>.tmp.<pid>.<ticks>`) and written through the descriptor
`open(O_CREAT|O_EXCL)` returned. A fixed temporary name would let a
symlink planted at that name redirect the write to another file, and
would let two concurrent writers interleave their bytes; this cannot.
On any failure the temporary is removed, so a failed write leaves the
target and its directory as they were.

`open`, `write`, `close`, `rename` and `unlink` are reached through the
same `dlopen` seam as the rest of the tool (`ffi.mojo`); Mojo 1.2's
`Path` can read and write text but cannot rename. `resolve_path` reaches
libc's `realpath` through the same seam: it is how a command path is
resolved to one absolute, symlink-free answer.

The mode is `0600` (what `O_EXCL` creation gives): a report is the
author's working file, and git records only the executable bit.
"""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import Pointer
from std.pathlib import Path
from std.time import monotonic

from skill_log.ffi import dl_sym

# `open(2)` flags and mode, as the Linux ABI numbers them.
comptime O_WRONLY = 1
comptime O_CREAT = 64
comptime O_EXCL = 128
comptime FILE_MODE = 384  # 0600


def read_text(path: String) raises -> String:
    """The file's text, or an error naming what could not be read.

    The caller checks existence first; a file that vanished between the
    check and the read is a real failure here, not an empty report.
    """
    return Path(path).read_text()


def c_string(text: String) -> List[UInt8]:
    """A NUL-terminated copy of `text`.

    `String.unsafe_ptr()` is read-only on this toolchain, so the
    terminator cannot be written in place; the copy is explicit.
    """
    var n = text.byte_length()
    var src = text.unsafe_ptr()
    var buf = List[UInt8](capacity=n + 1)
    for i in range(n):
        buf.append(src[unsafe_offset=i])
    buf.append(0)
    return buf^


def process_id() raises -> Int:
    """This process's id, for a temporary name no sibling uses."""
    var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
    var getpid = dl_sym[def() thin abi("C") -> Int](lib, "getpid")
    return getpid()


def temp_name(path: String) raises -> String:
    """A fresh sibling path: the target's name, this pid, this instant."""
    return (
        path
        + ".tmp."
        + String(process_id())
        + "."
        + String(Int(monotonic()))
    )


def unlink_path(path: String):
    """Remove `path`, best effort.

    Cleanup after a failed write must not replace the failure the caller
    is about to report, so nothing here raises.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var unlink_fn = dl_sym[def(Int) thin abi("C") -> Int](lib, "unlink")
        var buffer = c_string(path)
        _ = unlink_fn(Int(buffer.unsafe_ptr()))
        _ = buffer^
    except:
        return


def rename_path(from_path: String, to_path: String) raises:
    """`rename(2)`, as one atomic replacement inside a directory."""
    var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
    var rename_fn = dl_sym[def(Int, Int) thin abi("C") -> Int](
        lib, "rename"
    )
    var src = c_string(from_path)
    var dst = c_string(to_path)
    var rc = rename_fn(Int(src.unsafe_ptr()), Int(dst.unsafe_ptr()))
    _ = src^
    _ = dst^
    if rc != 0:
        raise Error("cannot replace " + to_path)


def resolve_path(path: String) -> String:
    """`path` as one absolute, symlink-resolved path, or "".

    libc's `realpath` does both jobs in one call: it resolves a relative
    path against the current directory and follows symlinks, so the same
    binary named three ways answers one path. It answers NULL when the
    file does not exist — an empty string here, and the caller keeps the
    name it was given. The answer is `malloc`'d, so it is copied out and
    freed. Nothing raises: resolution is best-effort, and a name the
    filesystem cannot resolve is still a usable command.
    """
    try:
        var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
        var realpath_fn = dl_sym[def(Int, Int) thin abi("C") -> Int](
            lib, "realpath"
        )
        var free_fn = dl_sym[def(Int) thin abi("C") -> Int](lib, "free")
        var buffer = c_string(path)
        var addr = realpath_fn(Int(buffer.unsafe_ptr()), 0)
        _ = buffer^
        if addr == 0:
            return ""
        var p = Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr)
        var out = String(
            StringSlice(unsafe_from_utf8=CStringSpan(unsafe_from_ptr=p))
        )
        _ = free_fn(addr)
        return out
    except:
        return ""


def write_text(path: String, text: String) raises:
    """Replace `path` with `text`, atomically.

    The temporary lives beside the target — a rename across filesystems
    is a copy, not an atomic swap — and is created with `O_EXCL`, so a
    file already at that name (a planted symlink included) is never
    followed. The bytes are written through the descriptor we opened, so
    nothing can swap the file out between creation and write.
    """
    var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
    var open_fn = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](lib, "open")
    var write_fn = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](
        lib, "write"
    )
    var close_fn = dl_sym[def(Int) thin abi("C") -> Int](lib, "close")

    var temp = temp_name(path)^
    var temp_buffer = c_string(temp)
    var fd = open_fn(
        Int(temp_buffer.unsafe_ptr()), O_WRONLY | O_CREAT | O_EXCL, FILE_MODE
    )
    _ = temp_buffer^
    if fd < 0:
        raise Error("cannot create a temporary file beside " + path)

    try:
        var offset = 0
        var total = text.byte_length()
        var base = Int(text.unsafe_ptr())
        while offset < total:
            var written = write_fn(fd, base + offset, total - offset)
            if written <= 0:
                raise Error("cannot write " + path)
            offset += written
    except e:
        _ = close_fn(fd)
        unlink_path(temp)
        raise e

    _ = close_fn(fd)
    try:
        rename_path(temp, path)
    except e:
        unlink_path(temp)
        raise e
