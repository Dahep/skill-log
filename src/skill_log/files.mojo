"""Reading and atomically replacing a small text file."""

from std.ffi import CStringSpan, OwnedDLHandle, RTLD, c_char
from std.memory import Pointer
from std.os import stat
from std.pathlib import Path
from std.time import monotonic

from skill_log.ffi import dl_sym

comptime O_WRONLY = 1
comptime O_CREAT = 64
comptime O_EXCL = 128
comptime FILE_MODE = 384  # 0600


def read_text(path: String) raises -> String:
    """The file's text, or an error naming what could not be read."""
    return Path(path).read_text()


def c_string(text: String) -> List[UInt8]:
    """A NUL-terminated copy of `text`."""
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
    """Remove `path`, best effort."""
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
    """`path` as one absolute, symlink-resolved path, or ""."""
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
    """Replace `path` with `text`, atomically, at the report mode 0600."""
    write_text_mode(path, text, FILE_MODE)


def is_executable(path: String) -> Bool:
    """True when the *owner* of `path` may execute it.

    The owner's bit is the one that matters, not "somebody's": git runs the
    hook as the user who pulled, and the installer wrote the file as that
    user. A file that cannot be stat'ed is not executable.
    """
    try:
        var info = stat(path)
        return (info.st_mode & 0o100) != 0
    except:
        return False


def set_executable(path: String) raises:
    """Give `path` the owner's execute bit, leaving its other bits alone."""
    var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
    var chmod_fn = dl_sym[def(Int, Int) thin abi("C") -> Int](lib, "chmod")
    var info = stat(path)
    var mode = info.st_mode | 0o100
    var buffer = c_string(path)
    var rc = chmod_fn(Int(buffer.unsafe_ptr()), mode)
    _ = buffer^
    if rc != 0:
        raise Error("cannot make " + path + " executable")


def write_text_mode(path: String, text: String, mode: Int) raises:
    """Replace `path` with `text`, atomically, at exactly `mode`.

    The temporary lives beside the target — a rename across filesystems is a
    copy, not an atomic swap — and is created with `O_EXCL`, so a file
    already at that name is never followed. The mode is set on the
    descriptor before the rename, so the replacement is never visible at the
    wrong permissions.
    """
    var lib = OwnedDLHandle("libc.so.6", RTLD.NOW)
    var open_fn = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](lib, "open")
    var write_fn = dl_sym[def(Int, Int, Int) thin abi("C") -> Int](
        lib, "write"
    )
    var close_fn = dl_sym[def(Int) thin abi("C") -> Int](lib, "close")
    var fchmod_fn = dl_sym[def(Int, Int) thin abi("C") -> Int](lib, "fchmod")

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
        if fchmod_fn(fd, mode) != 0:
            raise Error("cannot set the permissions on " + path)
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
