"""The C ABI seam: `dlopen`'s partner, spelled once.

Three places reach into a C library by symbol name — `context` (libc's
`gethostname`), `stdin` (libc's `isatty` and `read`), and `opendb`
(SQLite's entry points). Each needs the same three lines: look the symbol
up, refuse when it is missing, and call its address through a typed
pointer. That shape lives here, so a fix to it is one edit rather than
three.

The vendored binding under `vendor/sqlite/` keeps its own copy on purpose:
it is frozen upstream code with its own provenance, and this module must
not become a second fork of it.
"""

from std.ffi import OwnedDLHandle
from std.memory import Pointer


def dl_sym[FT: TrivialRegisterPassable](lib: OwnedDLHandle, name: String) raises -> FT:
    """Look up a C-ABI symbol as a plain callable value.

    `dlopen` gave us the handle, `dlsym` gives the address, and the
    address is called through a typed pointer. A symbol the library does
    not export is an error: the caller decided it needed that entry
    point, and a silent no-op would misreport every call after it.
    """
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("symbol not found: " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]
