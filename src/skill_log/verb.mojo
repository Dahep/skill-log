"""The verb table's shape."""

from skill_log.flags import takes_value


struct Verb(Movable):
    """One verb's metadata, as shown by `--help`.

    The help renderer reads the table like any other verb, so a
    subcommand's block is the common block and there is no second renderer
    to keep in step.
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
    """The index of the verb reached by `path`, or -1."""
    for i in range(len(verbs)):
        if verbs[i].path == path:
            return i
    return -1
