"""The adapter seam: opt-in code that fills context from a known harness.

ADR-0002's rule, in one place:

- **An adapter never runs unasked.** `SKILL_LOG_ADAPTERS=opencode` or
  `--adapter opencode` enables one. With neither, no adapter runs, and
  the row carries no harness and no model.
- **An adapter never beats the caller.** Its values sit below the
  explicit flag and below the field's `SKILL_LOG_*` variable in the
  precedence chain, and the chain is applied per field.
- **An adapter never sets `parent`.** The parent names a run this tool
  did not spawn; an adapter cannot know it.
- **An adapter's failure is a blank field, never an error.** Another
  program's schema is not this tool's contract, so an upstream change
  degrades to "unknown" rather than to a failed write.

Two adapters exist in 1.0:

| Adapter | Fills |
|---|---|
| `opencode` | `harness=opencode`, `session` from `OPENCODE_SESSION_ID`, `model` from opencode's session store |
| `t3` | `project`, from the worktree's path under T3 |

The `t3_thread` is never filled by an adapter: a thread id is not
invented. The dispatching skill knows it and passes it.
"""

from std.os import getenv
from std.pathlib import Path

from skill_log.detect import env_or_empty, t3_project
from skill_log.opendb import read_text_value

# The environment variable that names the adapters to run.
comptime ADAPTERS_ENV = "SKILL_LOG_ADAPTERS"

# The environment variable opencode exports into the shells it runs
# skills in.
comptime OPENCODE_SESSION_ENV = "OPENCODE_SESSION_ID"

# Where opencode keeps its session store.
comptime OPENCODE_DB_RELATIVE = "/.local/share/opencode/opencode.db"

# The table and column the model comes from.
comptime OPENCODE_MODEL_SQL = "SELECT model FROM session_v2 WHERE id = ?"


struct AdapterContext(Movable):
    """What an enabled adapter filled.

    Every field is a string; an empty one means the adapter did not
    fill it, or that it failed. The caller applies the precedence
    chain to these values, so an adapter never overwrites anything the
    caller said.
    """

    var harness: String
    var session: String
    var model: String
    var project: String

    def __init__(out self):
        self.harness = ""
        self.session = ""
        self.model = ""
        self.project = ""


def split_commas(text: String) -> List[String]:
    """Split a comma-separated list into its parts, trimmed.

    An empty part is dropped: `opencode,,t3` names two adapters, not
    three.
    """
    var parts = List[String]()
    var start = 0
    while True:
        var cut = text.find(",", start)
        var piece = ""
        if cut == -1:
            var tail = text[byte=start:]
            piece = String(tail)
        else:
            var middle = text[byte=start:cut]
            piece = String(middle)
        var trimmed = String(piece.strip())
        if trimmed != "":
            parts.append(trimmed)
        if cut == -1:
            break
        start = cut + 1
    return parts^


def env_adapters() -> List[String]:
    """The adapters `SKILL_LOG_ADAPTERS` names.

    The variable is comma-separated: `SKILL_LOG_ADAPTERS=opencode,t3`.
    """
    return split_commas(env_or_empty(ADAPTERS_ENV))


def enabled_adapters(flags: List[String]) -> List[String]:
    """The adapters to run: the flag's names plus the variable's.

    An adapter named by either is enabled. Duplicates are harmless —
    an adapter that fills the same field twice fills it the same way
    twice — so the list is not deduplicated here.
    """
    var names = List[String]()
    for i in range(len(flags)):
        var name = String(flags[i].strip())
        if name != "":
            names.append(name)
    var from_env = env_adapters()
    for i in range(len(from_env)):
        names.append(from_env[i])
    return names^


# ------------------------------------------------------------- the model


def json_string_field(text: String, key: String) -> String:
    """The value of a string field in a flat JSON object.

    A small targeted scanner, not a JSON parser: the only shape this
    tool reads is opencode's `{"id":"...","providerID":"..."}`, and the
    project has no JSON parser to borrow. The scan finds `"key"` at the
    top level of the object and reads the string that follows it.

    An empty string when the key is absent, when its value is not a
    string, or when the text is not a JSON object at all. The caller
    then leaves the value alone.
    """
    var needle = "\"" + key + "\""
    var at = text.find(needle)
    if at == -1:
        return ""

    var i = at + needle.byte_length()

    # Skip the whitespace between the key and its colon.
    while i < text.byte_length() and String(text[byte=i]) == " ":
        i += 1
    if i >= text.byte_length() or String(text[byte=i]) != ":":
        return ""
    i += 1

    # Skip the whitespace after the colon.
    while i < text.byte_length() and String(text[byte=i]) == " ":
        i += 1
    if i >= text.byte_length() or String(text[byte=i]) != "\"":
        return ""

    i += 1
    var out = String("")
    while i < text.byte_length():
        var c = String(text[byte=i])
        if c == "\\":
            # An escape: the next character stands for itself.
            if i + 1 >= text.byte_length():
                return out
            i += 1
            out += String(text[byte=i])
            i += 1
            continue
        if c == "\"":
            return out
        out += c
        i += 1
    return out


def render_model(raw: String) -> String:
    """An opencode model value as `provider/id`.

    The stored value is a JSON object such as
    `{"id":"kimi-k3","providerID":"opencode"}`, and the convention is
    `provider/id`. A value that is not that shape — an older shape, a
    bare id, something else entirely — is passed through unchanged: the
    reference does the same, and a value nobody can parse is better
    than a value silently mangled.
    """
    if raw == "":
        return ""
    if not raw.startswith("{"):
        return raw

    var provider = json_string_field(raw, "providerID")
    var model_id = json_string_field(raw, "id")
    if provider == "" or model_id == "":
        return raw
    return provider + "/" + model_id


# ----------------------------------------------------------- the adapters


def opencode_db_path() -> String:
    """The path of opencode's session store.

    The file is never created: the adapter checks that it exists
    before it opens it, because another tool's database is not this
    tool's to create.
    """
    return getenv("HOME", "") + OPENCODE_DB_RELATIVE


def opencode_model(session_id: String) -> String:
    """The model of an opencode session, or an empty string.

    The session store is read read-only; a missing file, a changed
    schema, an absent row — every one of them is an empty string.
    """
    if session_id == "":
        return ""
    var path = opencode_db_path()
    if not Path(path).is_file():
        return ""
    var raw = read_text_value(path, OPENCODE_MODEL_SQL, session_id)
    return render_model(raw)


def fill_opencode(mut context: AdapterContext):
    """Fill the opencode adapter's fields.

    `harness` is the adapter's own name — it is what the adapter is
    for. `session` comes from the environment opencode exports.
    `model` comes from opencode's session store.
    """
    context.harness = "opencode"

    var session = env_or_empty(OPENCODE_SESSION_ENV)
    context.session = session
    context.model = opencode_model(session)


def fill_t3(mut context: AdapterContext, worktree: String):
    """Fill the t3 adapter's field.

    The project grouping comes from the worktree's path under T3. A
    worktree outside T3 has no project, and one is never invented.
    """
    context.project = t3_project(worktree)


def apply_adapters(names: List[String], worktree: String) -> AdapterContext:
    """Run the enabled adapters and collect what they filled.

    `worktree` is the worktree the run happened in — the detected one,
    or the one the caller named. The t3 adapter needs it to find the
    project; the opencode adapter does not.

    An unknown adapter name is ignored: enabling an adapter this
    binary does not know must not fail the write.
    """
    var context = AdapterContext()
    for i in range(len(names)):
        var name = names[i].strip()
        if name == "opencode":
            fill_opencode(context)
        elif name == "t3":
            fill_t3(context, worktree)
    return context^
