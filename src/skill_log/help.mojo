"""The one help renderer.

It renders two things: the top-level usage (what `skill-log` with no
arguments, and `skill-log --help`, print) and a verb's own usage (what
`skill-log <verb> --help` prints). Both come out of the verb table, so a
verb added later needs no help text of its own — only its table entry.

Every rendered block ends with real, copy-pasteable invocations.
"""

from skill_log.verb import Verb


def render_verb(verb: Verb) -> String:
    """The usage block for one verb: its summary, its usage line, and
    two to four real invocations."""
    var text = verb.name + " — " + verb.summary + "\n"
    text += "\nusage:\n  " + verb.usage + "\n"
    text += "\nexamples:\n"
    # Indexed, not iterated: a `List` of non-Copyable elements cannot be
    # walked with `for`.
    for i in range(len(verb.examples)):
        text += "  " + verb.examples[i] + "\n"
    return text


def top_level_help(verbs: List[Verb]) -> String:
    """The top-level usage: what the tool is, how to call it, and the
    verbs it knows, each with real invocations."""
    var text = "skill-log — record agent-skill invocations and the friction they produced\n"
    text += "\nusage:\n"
    text += "  skill-log <verb> [options]\n"
    text += "  skill-log            print this usage\n"
    text += "\nverbs:\n"
    for i in range(len(verbs)):
        text += "  " + verbs[i].name + "  " + verbs[i].summary + "\n"
    text += "\nexamples:\n"
    text += "  skill-log --version\n"
    text += "  skill-log --help\n"
    return text
