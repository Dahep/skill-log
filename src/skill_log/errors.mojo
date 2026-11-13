"""The one error and exit path."""

from std.sys import stderr, exit

from skill_log.text import sanitize

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
    """What a handler returns: text to print, or a failure to report."""

    var text: String
    var failure: Failure
    var failed: Bool
    var usage: String
    var notes: String

    def __init__(out self, text: String):
        self.text = text
        self.failure = Failure("", EXIT_OK())
        self.failed = False
        self.usage = ""
        self.notes = ""

    @staticmethod
    def ok(text: String) -> Outcome:
        """Succeed, with `text` to print on stdout."""
        var outcome = Outcome(text)
        return outcome^

    @staticmethod
    def ok_notes(text: String, notes: String) -> Outcome:
        """Succeed, with `text` on stdout and `notes` on stderr."""
        var outcome = Outcome(text)
        outcome.notes = notes
        return outcome^

    @staticmethod
    def fail(message: String, code: Int) -> Outcome:
        """Fail with `message` and exit `code`."""
        var outcome = Outcome("")
        outcome.failure = Failure(message, code)
        outcome.failed = True
        return outcome^

    @staticmethod
    def fail_notes(message: String, code: Int, notes: String) -> Outcome:
        """Fail with one summary line plus `notes` on stderr."""
        var outcome = Outcome.fail(message, code)
        outcome.notes = notes
        return outcome^

    @staticmethod
    def usage_error(usage: String) -> Outcome:
        """Exit 2 with the usage block on stderr."""
        var outcome = Outcome("")
        outcome.failure = Failure("usage", EXIT_USAGE())
        outcome.failed = True
        outcome.usage = usage
        return outcome^


def report(failure: Failure):
    """Write the single stderr line this failure is allowed."""
    print("skill-log: " + sanitize(failure.message), file=stderr)


def fail(failure: Failure):
    """Report the failure and exit with its code. Never returns."""
    report(failure)
    exit(failure.code)
