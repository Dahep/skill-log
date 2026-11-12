"""Reading a flag's value, once.

Every verb's parser takes a value the same way: the value sits at
`at + 1`, a missing value is a usage error naming the flag, and the value
is taken as written whatever it looks like (`--problem -h` is the text
`-h`). One function, so a flag added later cannot forget the check or
invent its own wording for it.
"""


def take_value(
    args: List[String], at: Int, flag: String, what: String
) raises -> String:
    """The value of `flag`, which sits at `at + 1`.

    Raises a `usage:` error when the flag is the last argument. The
    caller turns the marker into exit 2.
    """
    var next = at + 1
    if next >= len(args):
        raise Error("usage: " + flag + " needs " + what)
    return String(args[next])
