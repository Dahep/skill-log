"""Reading a flag's value, once.

Every verb's parser takes a value the same way: the value sits at
`at + 1`, a missing value is a usage error naming the flag, and the value
is taken as written whatever it looks like (`--problem -h` is the text
`-h`). One function, so a flag added later cannot forget the check or
invent its own wording for it.

A verb also declares which of its flags take a value. The declaration
lives with the parser — the same place the assignment happens — and
`take_value` checks the flag against it, so a flag added to one and not
the other cannot happen: the parser refuses to read a value for a flag
the verb did not declare.
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


def take_declared_value(
    args: List[String],
    at: Int,
    flag: String,
    what: String,
    value_flags: List[String],
) raises -> String:
    """The value of `flag`, which the verb must have declared.

    The check is here, at the one place every verb reads a value, so a
    flag the parser handles but the declaration does not name is caught
    at once: the parser and the dispatcher can never disagree about
    which flags take a value.
    """
    if not takes_value(value_flags, flag):
        raise Error("usage: " + flag + " is not a value flag")
    return take_value(args, at, flag, what)


def takes_value(flags: List[String], flag: String) -> Bool:
    """True when `flag` is one of the value-taking flags."""
    for i in range(len(flags)):
        if flags[i] == flag:
            return True
    return False


def parse_positive(value: String, message: String) raises -> Int:
    """A positive decimal number, or a usage error carrying `message`.

    Digits only: a sign, a space or a fraction is not an invocation id.
    The cap is checked while the digits are consumed, so an oversized
    number cannot wrap into the valid range.
    """
    var text = String(value.strip())
    if text == "":
        raise Error("usage: " + message)
    var number = 0
    for c in text.codepoints():
        var code = Int(c)
        if code < 48 or code > 57:
            raise Error("usage: " + message)
        number = number * 10 + (code - 48)
        if number > 2_000_000_000:
            raise Error("usage: " + message)
    if number < 1:
        raise Error("usage: " + message)
    return number
