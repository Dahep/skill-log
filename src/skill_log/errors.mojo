"""The one error and exit path."""

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

        A handler never writes to a stream. A usage failure carries the
        usage block in `usage`: it is printed on stderr so stdout stays
        empty."""

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
        """Succeed, with `text` on stdout and `notes` on stderr.

        The notes are what a verb has to say that is not the answer:
        rows it skipped, a validator's warnings. They are already
        prefixed and one line each; `main` prints them without adding
        anything.
        """
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
        """Fail with one summary line plus `notes` on stderr.

        A validator reports every finding it can see; the summary is the
        one line the failure still gets, and the notes are the detail the
        caller asked for by running `--check`.
        """
        var outcome = Outcome.fail(message, code)
        outcome.notes = notes
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

        Every control character in the message becomes a space: the
        contract is one line, not one per control character."""
    print("skill-log: " + sanitize(failure.message), file=stderr)


def fail(failure: Failure):
    """Report the failure and exit with its code. Never returns."""
    report(failure)
    exit(failure.code)
