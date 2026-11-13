"""The C ABI seam: `dlopen`'s partner, spelled once."""

from std.ffi import OwnedDLHandle
from std.memory import Pointer


def dl_sym[FT: TrivialRegisterPassable](lib: OwnedDLHandle, name: String) raises -> FT:
    """Look up a C-ABI symbol as a plain callable value."""
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("symbol not found: " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]
