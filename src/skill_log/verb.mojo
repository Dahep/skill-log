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
    """

    var name: String
    var summary: String
    var usage: String
    var examples: List[String]
    var notes: String

    def __init__(
        out self,
        name: String,
        summary: String,
        usage: String,
        examples: List[String],
        notes: String = "",
    ):
        self.name = name
        self.summary = summary
        self.usage = usage
        self.examples = examples.copy()
        self.notes = notes
