"""The one error and exit path.

Every failure the CLI can produce is a `Failure`: a message and an exit code.
The codes are the contract from issue #1:

- 0 — success, or nothing to do
- 1 — operational failure (the store, the filesystem, the environment)
- 2 — usage error (unknown verb, bad flag, missing argument)

A handler returns what to print; it never prints and it never exits.
`report`/`fail` below are the single failure path — one sanitized line on
stderr, then the exit code — and `main` and the preflight call them rather
than printing a failure themselves.
"""

from std.sys import stderr, exit

from skill_log.text import sanitize

# Exit codes, named so a handler cannot invent a fourth one.
def EXIT_OK() -> Int:
    return 0


def EXIT_FAILURE() -> Int:
    return 1


def EXIT_USAGE() -> Int:
    return 2


struct Failure:
    """A failure the CLI reports as exactly one stderr line."""

    var message: String
    var code: Int

    def __init__(out self, message: String, code: Int):
        self.message = message
        self.code = code


def operational_failure(message: String) -> Failure:
    """An operational failure: exit code 1."""
    return Failure(message, EXIT_FAILURE())


struct Outcome:
    """What a handler returns: text to print, or a failure to report.

    A handler never writes to a stream. It returns the text it wants on
    stdout, or a `Failure` that `main` turns into one stderr line and an
    exit code.

    A usage failure carries the usage block in `usage`: it is printed on
    stderr so stdout stays empty, and the block is the whole diagnostic —
    the caller asked for nothing in particular, so the answer is how to
    call the tool.
    """

    var text: String
    var failure: Failure
    var failed: Bool
    var usage: String

    def __init__(out self, text: String):
        self.text = text
        self.failure = Failure("", EXIT_OK())
        self.failed = False
        self.usage = ""

    @staticmethod
    def ok(text: String) -> Outcome:
        """Succeed, with `text` to print on stdout."""
        var outcome = Outcome(text)
        return outcome^

    @staticmethod
    def fail(message: String, code: Int) -> Outcome:
        """Fail with `message` and exit `code`."""
        var outcome = Outcome("")
        outcome.failure = Failure(message, code)
        outcome.failed = True
        return outcome^

    @staticmethod
    def usage_error(usage: String) -> Outcome:
        """Exit 2 with the usage block on stderr.

        The usage block *is* the diagnostic here — the caller asked for
        nothing in particular, so the answer is how to call the tool. No
        extra `skill-log: ` line is added on top of it.
        """
        var outcome = Outcome("")
        outcome.failure = Failure("usage", EXIT_USAGE())
        outcome.failed = True
        outcome.usage = usage
        return outcome^


def report(failure: Failure):
    """Write the single stderr line this failure is allowed.

    Every line is prefixed `skill-log: ` so a caller can recognise it
    without parsing the message, and every control character in the
    message becomes a space: a path or an option can carry a newline of
    its own, and the contract is one line, not one per control character.
    """
    print("skill-log: " + sanitize(failure.message), file=stderr)


def fail(failure: Failure):
    """Report the failure and exit with its code. Never returns."""
    report(failure)
    exit(failure.code)
