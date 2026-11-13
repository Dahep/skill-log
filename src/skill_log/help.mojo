"""The one help renderer.

It renders two things: the top-level usage (what `skill-log` with no
arguments, and `skill-log --help`, print) and a verb's own usage (what
`skill-log <verb> --help` prints). Both come out of the verb table, so a
verb added later needs no help text of its own — only its table entry.

The levels below a verb are rendered the same way: `skills audit --help`
renders the `audit` verb's block, and `skills template show --help`
renders the `show` verb's block, which the table holds beside the
others. Every level comes out of the same table, so a subcommand needs
no help text of its own either.

Every rendered block ends with real, copy-pasteable invocations.
"""

from skill_log.verb import Verb


def render_verb(verb: Verb) -> String:
    """The usage block for one verb: its summary, its usage line, its
    notes, and two to four real invocations."""
    var text = verb.path + " — " + verb.summary + "\n"
    text += "\nusage:\n  " + verb.usage + "\n"
    if verb.notes != "":
        text += "\n" + verb.notes + "\n"
    text += "\nexamples:\n"
    # Indexed, not iterated: a `List` of non-Copyable elements cannot be
    # walked with `for`.
    for i in range(len(verb.examples)):
        text += "  " + verb.examples[i] + "\n"
    return text


def render_verb_list(verbs: List[Verb]) -> String:
    """The list of verbs: one line per verb, name and summary.

    The same list the top-level usage prints, so a verb lists its
    sub-verbs the way the tool lists everything else.
    """
    var text = String("")
    for i in range(len(verbs)):
        text += "  " + verbs[i].name + "  " + verbs[i].summary + "\n"
    return text


def top_level_help(verbs: List[Verb]) -> String:
    """The top-level usage: what the tool is, how to call it, and the
    verbs it knows.

    The verb list is one line per verb, not one example each: the
    per-verb invocations live in the verb's own `--help`, which is
    where a caller looks for them.
    """
    var text = "skill-log — record agent-skill invocations and the friction they produced\n"
    text += "\nusage:\n"
    text += "  skill-log <verb> [options]\n"
    text += "  skill-log            print this usage\n"
    text += "\nverbs:\n"
    text += render_verb_list(verbs)
    text += "\nexamples:\n"
    text += "  skill-log --version\n"
    text += "  skill-log --help\n"
    return text
