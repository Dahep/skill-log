"""The verb registry: one table entry per verb.

A verb is a row in one table. Adding a verb later means adding one entry to
`build_verbs` and one handler to `build_handlers` — never a new file tree.

Each entry carries the verb's name, a one-line summary, its usage line, and
two to four real invocations. The handler lives beside the entry in the
parallel list `build_handlers`; Mojo 1.2 has no callable-typed struct field,
so the two lists stay in step by index.

A handler receives the arguments that follow the verb name and returns the
text to print. It never prints itself and it never calls `exit`: `main` owns
both. A handler that fails returns a `Failure`, which `main` reports as one
stderr line with the matching exit code.

Only verbs that actually work are registered. There is no "not implemented"
stub: a later ticket appends its verb here when it lands.
"""

from skill_log.add import handle_add
from skill_log.errors import Outcome
from skill_log.help import top_level_help
from skill_log.verb import Verb
from skill_log.version import version

# The shared signature of every handler. Mojo 1.2 rejects an `alias` for a
# function type at file scope, so the concrete closure type is taken from
# `handle_version` below and reused as the element type of the handler list.


def handle_version(args: List[String]) raises -> Outcome:
    """Print the release version baked in at build time."""
    _ = args
    return Outcome.ok(version())


def handle_help(args: List[String]) raises -> Outcome:
    """Print the top-level usage and the copy-pasteable examples."""
    _ = args
    return Outcome.ok(top_level_help(build_verbs()))


def build_verbs() raises -> List[Verb]:
    """The verb table, in the order `--help` lists them."""
    var verbs = List[Verb]()

    var add_examples = List[String]()
    add_examples.append("skill-log add --skill diagnosing-bugs")
    add_examples.append(
        'skill-log add --skill diagnosing-bugs --problem "step 3 assumed a core dump exists"'
    )
    add_examples.append(
        'skill-log add --skill create-skill --problem - < notes.txt'
    )
    add_examples.append("skill-log add --skill create-skill --dry-run --json")
    verbs.append(
        Verb(
            "add",
            "record one skill invocation and the friction it produced",
            "skill-log add --skill <name> [--problem <text>]...\n"
            "                   [--harness <name>] [--session <id>] [--parent <id>]\n"
            "                   [--model <provider/id>] [--repo <name>]\n"
            "                   [--worktree <path>] [--project <name>]\n"
            "                   [--t3-thread <id>] [--machine <name>]\n"
            "                   [--adapter <name>]... [--dry-run] [--json] [--db <path>]",
            add_examples,
            "A clean run still writes a row: the invocation count is the\n"
            "denominator of the problems-per-invocation rate.\n"
            "\n"
            "add is not idempotent. The log records occurrences, so a retry\n"
            "after a crashed run is indistinguishable from a genuine repeat\n"
            "and deduping would hide the second occurrence of one error.\n"
            "Two identical calls therefore produce two rows.\n"
            "\n"
            "Context fields resolve by one chain, per field: the explicit\n"
            "flag, then its SKILL_LOG_* variable, then an enabled adapter,\n"
            "then the built-in detection. An empty field means unknown.\n"
            "The machine is always detected; --machine names it instead.\n"
            "\n"
            "Adapters never run unasked. Enable one with --adapter opencode\n"
            "or SKILL_LOG_ADAPTERS=opencode. Both take a comma-separated\n"
            "list, and --adapter may be repeated. The opencode adapter\n"
            "fills harness, session and model; the t3 adapter fills\n"
            "project. An adapter never sets parent, and its failure is a\n"
            "blank field rather than an error.\n"
            "\n"
            "--problem - reads the problem text from stdin, and exits 2\n"
            "instead of waiting when stdin is a terminal.",
        )
    )

    var version_examples = List[String]()
    version_examples.append("skill-log --version")
    version_examples.append("skill-log --help")
    verbs.append(
        Verb(
            "--version",
            "print the release version",
            "skill-log --version",
            version_examples,
        )
    )

    var help_examples = List[String]()
    help_examples.append("skill-log --help")
    help_examples.append("skill-log -h")
    help_examples.append("skill-log --version")
    verbs.append(
        Verb(
            "--help",
            "print this usage and the available verbs",
            "skill-log --help",
            help_examples,
        )
    )

    return verbs^


def build_handlers() raises -> List[type_of(handle_version)]:
    """The handler table, indexed in step with `build_verbs`."""
    var handlers = List[type_of(handle_version)]()
    handlers.append(handle_add)
    handlers.append(handle_version)
    handlers.append(handle_help)
    return handlers^
