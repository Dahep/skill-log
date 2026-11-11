"""The entry point.

`main` is the only place that writes to stdout or stderr and the only place
that sets an exit code. Everything else returns what to print.

The order is fixed:

1. The SQLite preflight loads the vendored binding. It runs for every
   invocation, `--version` and `--help` included, so a missing or
   unloadable `libsqlite3.so.0` is one named stderr line and exit 1 rather
   than a traceback.
2. The verb is looked up in the registry. No arguments is a usage error:
   usage plus examples, exit 2.
3. The handler runs and returns text, or a failure.
4. The catch-all turns anything that escapes into one stderr line and
   exit 1. No Mojo traceback ever reaches the user.

Usage errors (exit 2) print the usage and the examples on stderr, because
stdout stays empty on failure; the `--help` form of the same text prints on
stdout and exits 0.
"""

from std.sys import argv, exit, stderr, stdout

from skill_log.errors import EXIT_FAILURE, EXIT_OK, EXIT_USAGE, Outcome, fail
from skill_log.help import render_verb, top_level_help
from skill_log.registry import build_handlers, build_verbs
from skill_log.sqlite_preflight import preflight


def find_verb(name: String) raises -> Optional[Int]:
    """The index of the verb called `name`, or `None`."""
    var verbs = build_verbs()
    for i in range(len(verbs)):
        if verbs[i].name == name:
            return i
    return None


def command_line_args() -> List[String]:
    """The arguments after the program name, as owned strings."""
    var args = List[String]()
    var all = argv()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    return args^


def tail(args: List[String]) -> List[String]:
    """The arguments after the first one, as an owned list.

    A slice of a `List` is a `Span`, and Mojo 1.2 has no way to spell a
    `Span`'s origin in a handler signature, so the tail is copied.
    """
    var rest = List[String]()
    for i in range(1, len(args)):
        rest.append(args[i])
    return rest^


def run(args: List[String]) raises -> Outcome:
    """Turn the arguments after the program name into what to print."""
    if len(args) == 0:
        # No arguments is a usage error: the usage and the examples, exit 2.
        return Outcome.usage_error(top_level_help(build_verbs()))

    var name = args[0]

    if name == "-h":
        # `-h` is the short form of `--help`.
        return Outcome.ok(top_level_help(build_verbs()))

    var index = find_verb(name)
    if index is None:
        # An unknown verb is one named line. The usage block would be
        # noise on top of it.
        return Outcome.fail("unknown verb: " + name, EXIT_USAGE())

    var handlers = build_handlers()
    var rest = tail(args)

    # `skill-log <verb> --help` prints that verb's own usage and its real
    # invocations, and exits 0.
    for i in range(len(rest)):
        if rest[i] == "--help" or rest[i] == "-h":
            var verbs = build_verbs()
            return Outcome.ok(render_verb(verbs[index.value()]))

    return handlers[index.value()](rest)


def main():
    # The catch-all. Anything that escapes a handler — a bug, an
    # unexpected condition — becomes one named stderr line, never a Mojo
    # runtime banner.
    try:
        var args = command_line_args()

        # The SQLite preflight runs before dispatch, for every invocation.
        var preflight_failure = preflight()
        if preflight_failure:
            fail(preflight_failure.value())

        var outcome = run(args)

        if outcome.failed:
            if outcome.usage != "":
                # A usage error prints the usage and the examples on
                # stderr, so stdout stays empty. The block is the whole
                # diagnostic; no extra named line is added on top of it.
                print(outcome.usage, file=stderr)
                exit(outcome.failure.code)
            fail(outcome.failure)

        # An empty text is an empty output, not a blank line: a JSON
        # stream with no rows must stay parseable, and a stray newline
        # would not be a JSON line.
        if outcome.text != "":
            print(outcome.text, file=stdout)
        exit(EXIT_OK())
    except e:
        # The catch-all: one line, exit 1, no traceback.
        print("skill-log: " + String(e), file=stderr)
        exit(EXIT_FAILURE())
