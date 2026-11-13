"""The verb table's shape."""

from skill_log.flags import takes_value


struct Verb(Movable):
    """One verb's metadata, as shown by `--help`.

    `notes` is the paragraph between the usage line and the examples:
    the things a caller has to know before running the verb, such as the
    fact that `add` records occurrences rather than state.

    `value_flags` lists the flags that consume the argument after them.
    The dispatcher needs that to tell a help request from a *value*
    spelled like one: `add --skill x -h` asks for help, while
    `add --problem -h` records the problem `-h`. The list sits beside
    the usage line that documents the same flags, so the two are read
    together.

    `path` is the path the verb is reached by, space-separated: `skills`
    for the top-level verb, `skills template show` for a sub-command of
    a sub-command. `name` is the last word of that path — the word the
    caller types after its parent.
    """

    var name: String
    var path: String
    var summary: String
    var usage: String
    var examples: List[String]
    var value_flags: List[String]
    var notes: String
    var nested_help: Bool

    def __init__(
        out self,
        name: String,
        summary: String,
        usage: String,
        examples: List[String],
        value_flags: List[String],
        notes: String = "",
        nested_help: Bool = False,
        path: String = "",
    ):
        self.name = name
        # A verb is reached by its name unless the caller says otherwise:
        # a top-level verb is called by the word it is named.
        self.path = path if path != "" else name
        self.summary = summary
        self.usage = usage
        self.examples = examples.copy()
        self.value_flags = value_flags.copy()
        self.notes = notes
        self.nested_help = nested_help

    def takes_value(self, arg: String) -> Bool:
        """True when `arg` is one of this verb's value-taking flags."""
        return takes_value(self.value_flags, arg)


def find_verb(verbs: List[Verb], path: String) -> Int:
    """The index of the verb reached by `path`, or -1.

    The path is the space-separated words the caller types after the
    tool: `skills`, `skills template`, `skills template show`.

    The index is the answer rather than the verb: a `Verb` is movable
    and not copyable, so handing one over means the caller takes it out
    of the table, and the table is still wanted by the reader.
    """
    for i in range(len(verbs)):
        if verbs[i].path == path:
            return i
    return -1
