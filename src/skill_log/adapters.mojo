"""The adapter seam: opt-in code that fills context from a known harness."""

from std.os import getenv
from std.pathlib import Path

from skill_log.detect import env_or_empty, t3_project
from skill_log.opendb import read_text_value

comptime ADAPTERS_ENV = "SKILL_LOG_ADAPTERS"

comptime OPENCODE_SESSION_ENV = "OPENCODE_SESSION_ID"

comptime OPENCODE_DB_RELATIVE = "/.local/share/opencode/opencode.db"

comptime OPENCODE_MODEL_SQL = "SELECT model FROM session_v2 WHERE id = ?"


struct AdapterContext(Movable):
    """What an enabled adapter filled."""

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
    """Split a comma-separated list into its parts, trimmed."""
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
    """The adapters `SKILL_LOG_ADAPTERS` names."""
    return split_commas(env_or_empty(ADAPTERS_ENV))


def enabled_adapters(flags: List[String]) -> List[String]:
    """The adapters to run: the flag's names plus the variable's."""
    var names = List[String]()
    for i in range(len(flags)):
        var parts = split_commas(flags[i])
        for j in range(len(parts)):
            names.append(parts[j])
    var from_env = env_adapters()
    for i in range(len(from_env)):
        names.append(from_env[i])
    return names^




def is_json_space(ch: String) -> Bool:
    """True for the whitespace JSON allows between tokens."""
    return ch == " " or ch == "\n" or ch == "\r" or ch == "\t"


def json_string_span(text: String, at: Int) -> Int:
    """The index just past the closing quote of the string opening at `at`."""
    var n = text.byte_length()
    var i = at + 1
    while i < n:
        var c = String(text[byte=i])
        if c == "\\":
            i += 2
            continue
        if c == "\"":
            return i + 1
        i += 1
    return -1


def json_string_value(text: String, at: Int) -> String:
    """The text of the string that opens at `at`, its escapes resolved."""
    var end = json_string_span(text, at)
    if end == -1:
        return ""
    var inner = String(text[byte=at + 1:end - 1])
    if inner.find("\\") == -1:
        return inner

    var out = String("")
    var i = 0
    while i < inner.byte_length():
        var c = String(inner[byte=i])
        if c != "\\":
            out += c
            i += 1
            continue
        if i + 1 >= inner.byte_length():
            return ""
        var escape = String(inner[byte=i + 1])
        if escape == "\"":
            out += "\""
        elif escape == "\\":
            out += "\\"
        elif escape == "/":
            out += "/"
        elif escape == "n":
            out += "\n"
        elif escape == "t":
            out += "\t"
        elif escape == "r":
            out += "\r"
        elif escape == "b":
            out += "\b"
        elif escape == "f":
            out += "\f"
        else:
            return ""
        i += 2
    return out


def json_string_field(text: String, key: String) -> String:
    """The value of a string field at the top level of a JSON object.

    A small targeted scanner, not a JSON parser: the only shape this tool
    reads is opencode's `{"id":"...","providerID":"..."}`. The scan
    tracks nesting, so a key spelled inside a nested object never answers
    for the top-level one.
    """
    var n = text.byte_length()
    var i = 0
    while i < n and is_json_space(String(text[byte=i])):
        i += 1
    if i >= n or String(text[byte=i]) != "{":
        return ""
    i += 1

    var depth = 1
    while i < n:
        var c = String(text[byte=i])
        if c == "\"":
            var end = json_string_span(text, i)
            if end == -1:
                return ""
            var name = json_string_value(text, i)
            i = end

            var j = i
            while j < n and is_json_space(String(text[byte=j])):
                j += 1
            if j < n and String(text[byte=j]) == ":":
                if depth == 1 and name == key:
                    var k = j + 1
                    while k < n and is_json_space(String(text[byte=k])):
                        k += 1
                    if k < n and String(text[byte=k]) == "\"":
                        return json_string_value(text, k)
                    return ""
                i = j + 1
            continue

        if c == "{" or c == "[":
            depth += 1
        elif c == "}" or c == "]":
            depth -= 1
            if depth == 0:
                return ""
        i += 1
    return ""


def render_model(raw: String) -> String:
    """An opencode model value as `provider/id`."""
    if raw == "":
        return ""
    if not raw.startswith("{"):
        return raw

    var provider = json_string_field(raw, "providerID")
    var model_id = json_string_field(raw, "id")
    if provider == "" or model_id == "":
        return raw
    return provider + "/" + model_id




def opencode_db_path() -> String:
    """The path of opencode's session store."""
    return getenv("HOME", "") + OPENCODE_DB_RELATIVE


def opencode_model(session_id: String) -> String:
    """The model of an opencode session, or an empty string."""
    if session_id == "":
        return ""
    var path = opencode_db_path()
    if not Path(path).is_file():
        return ""
    var raw = read_text_value(path, OPENCODE_MODEL_SQL, session_id)
    return render_model(raw)


def fill_opencode(mut context: AdapterContext):
    """Fill the opencode adapter's fields."""
    context.harness = "opencode"

    var session = env_or_empty(OPENCODE_SESSION_ENV)
    context.session = session
    context.model = opencode_model(session)


def fill_t3(mut context: AdapterContext, worktree: String):
    """Fill the t3 adapter's field."""
    context.project = t3_project(worktree)


def apply_adapters(names: List[String], worktree: String) -> AdapterContext:
    """Run the enabled adapters and collect what they filled."""
    var context = AdapterContext()
    for i in range(len(names)):
        var name = names[i].strip()
        if name == "opencode":
            fill_opencode(context)
        elif name == "t3":
            fill_t3(context, worktree)
    return context^
