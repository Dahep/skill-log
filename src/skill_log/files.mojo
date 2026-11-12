"""Reading and atomically replacing a small text file.

A report file is committed with a change, so a half-written one — a
crash between `truncate` and the last marker — would be a corrupted
artifact in the tree. The write goes to a sibling temporary file and is
then renamed over the target: `rename(2)` inside one directory is atomic,
so a reader sees either the old report or the new one, never a mixture.

`rename` and the NUL-terminated argument buffers it needs are reached
through the same `dlopen` seam the rest of the tool uses (`ffi.mojo`);
Mojo 1.2's `Path` can read and write text but cannot rename.

Nothing here creates a directory. The caller decides whether the report
directory exists, because that decision is the artifact-versus-trailer
mode switch, not a filesystem detail.
"""

from std.ffi import OwnedDLHandle, RTLD
from std.pathlib import Path

from skill_log.ffi import dl_sym


def read_text(path: String) raises -> String:
    """The file's text, or an error naming what could not be read.

    The caller checks existence first; a file that vanished between the
    check and the read is a real failure here, not an empty report.
    """
    return Path(path).read_text()


def write_text(path: String, text: String) raises:
    """Replace `path` with `text`, atomically.

    The temporary file lives beside the target — a rename across
    filesystems is a copy, not an atomic swap — and carries a name no
    other write of this report uses, so two writers cannot interleave.
    """
    var temp = path + ".tmp"
    var temp_path = Path(temp)
    temp_path.write_text(text)
    rename_path(temp, path)


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


def rename_path(from_path: String, to_path: String) raises:
    """`rename(2)`, as one atomic replacement inside a directory.

    Both paths are passed as NUL-terminated buffers; the call is the
    same one `mv` uses for the same job.
    """
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
