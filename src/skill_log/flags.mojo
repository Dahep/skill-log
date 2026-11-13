"""Reading a flag's value, once."""


def take_value(
    args: List[String], at: Int, flag: String, what: String
) raises -> String:
    """The value of `flag`, which sits at `at + 1`."""
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
    """The value of `flag`, which the verb must have declared."""
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
    """A positive decimal number, or a usage error carrying `message`."""
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
