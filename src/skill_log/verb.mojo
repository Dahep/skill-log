"""One row of the verb table.

`Verb` is the row type: what the registry stores, what the help renderer
reads. It lives in its own module so that the registry and the renderer
both depend on it and neither depends on the other.
"""


struct Verb:
    """One verb's metadata, as shown by `--help`.

    `notes` is the paragraph between the usage line and the examples:
    the things a caller has to know before running the verb, such as the
    fact that `add` records occurrences rather than state.

    `value_flags` lists the flags that consume the argument after them.
    The dispatcher needs that to tell a help request from a *value*
    spelled like one: `add --skill x -h` asks for help, while
    `add --problem -h` records the problem `-h`. The list is written once
    here, next to the usage line that documents the same flags.
    """

    var name: String
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
    ):
        self.name = name
        self.summary = summary
        self.usage = usage
        self.examples = examples.copy()
        self.value_flags = value_flags.copy()
        self.notes = notes
        self.nested_help = nested_help

    def takes_value(self, arg: String) -> Bool:
        """True when `arg` is one of this verb's value-taking flags."""
        for i in range(len(self.value_flags)):
            if self.value_flags[i] == arg:
                return True
        return False
