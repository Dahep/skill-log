"""One renderer for every level of the verb tree."""

from skill_log.verb import Verb


def render_verb(verb: Verb) -> String:
    """The usage block for one verb: its summary, its usage line, its"""
    var text = verb.path + " — " + verb.summary + "\n"
    text += "\nusage:\n  " + verb.usage + "\n"
    if verb.notes != "":
        text += "\n" + verb.notes + "\n"
    text += "\nexamples:\n"
    for i in range(len(verb.examples)):
        text += "  " + verb.examples[i] + "\n"
    return text


def render_verb_list(verbs: List[Verb]) -> String:
    """The list of verbs: one line per verb, name and summary."""
    var text = String("")
    for i in range(len(verbs)):
        text += "  " + verbs[i].name + "  " + verbs[i].summary + "\n"
    return text


def top_level_help(verbs: List[Verb]) -> String:
    """The top-level usage: what the tool is, how to call it, and the"""
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
