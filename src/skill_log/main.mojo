"""The entry point: parse, dispatch, report."""

from std.sys import argv, exit, stderr, stdout

from skill_log.errors import EXIT_FAILURE, EXIT_OK, EXIT_USAGE, Outcome, fail
from skill_log.help import render_verb, top_level_help
from skill_log.registry import build_handlers, build_verbs
from skill_log.sqlite_preflight import preflight
from skill_log.text import sanitize
from skill_log.verb import find_verb


def command_line_args() -> List[String]:
    """The arguments after the program name, as owned strings."""
    var args = List[String]()
    var all = argv()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    return args^


def tail(args: List[String]) -> List[String]:
    """The arguments after the first one, as an owned list."""
    var rest = List[String]()
    for i in range(1, len(args)):
        rest.append(args[i])
    return rest^


def run(args: List[String]) raises -> Outcome:
    """Turn the arguments after the program name into what to print."""
    if len(args) == 0:
        return Outcome.usage_error(top_level_help(build_verbs()))

    var name = args[0]

    if name == "-h":
        return Outcome.ok(top_level_help(build_verbs()))

    var verbs = build_verbs()

    var index = find_verb(verbs, name)
    if index == -1:
        return Outcome.fail("unknown verb: " + name, EXIT_USAGE())
    var handlers = build_handlers()
    var rest = tail(args)

    var nested = verbs[index].nested_help
    var i = 0
    while i < len(rest):
        if rest[i] == "--help" or rest[i] == "-h":
            if nested:
                return handlers[index](rest)
            return Outcome.ok(render_verb(verbs[index]))
        if verbs[index].takes_value(rest[i]):
            i += 1
        i += 1

    return handlers[index](rest)


def main():
    try:
        var args = command_line_args()

        var preflight_failure = preflight()
        if preflight_failure:
            fail(preflight_failure.value())

        var outcome = run(args)

        if outcome.failed:
            if outcome.text != "":
                print(outcome.text, file=stdout)
            if outcome.notes != "":
                print(outcome.notes, file=stderr)
            if outcome.usage != "":
                print(outcome.usage, file=stderr)
                exit(outcome.failure.code)
            fail(outcome.failure)

        if outcome.notes != "":
            print(outcome.notes, file=stderr)

        if outcome.text != "":
            print(outcome.text, file=stdout)
        exit(EXIT_OK())
    except e:
        print("skill-log: " + sanitize(String(e)), file=stderr)
        exit(EXIT_FAILURE())
