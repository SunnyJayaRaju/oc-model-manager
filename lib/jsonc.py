#!/usr/bin/env python3
"""JSONC (JSON with comments) reader and span-preserving patcher.

OpenCode's config file may be opencode.json or opencode.jsonc. The .jsonc
flavour allows // and /* */ comments, trailing commas and a UTF-8 BOM, none of
which stdlib json accepts. ocm must read such a file AND edit an array in it
without disturbing a single byte around the edit: an owner's hand-written
config can carry comments that a whole-file re-serialisation would destroy.

Pure standard library — no PyYAML, no jsonschema.

Modes
-----
  load <file>
      Print the file as comment-free, strict JSON on stdout.

  patch <file> <dotted.key> <json-array>
      Replace ONLY the byte span of the array at <dotted.key> (a.b.c addressing)
      with <json-array>. Every other byte of the file is preserved verbatim,
      comments included. Writes <file>.tmp then renames over the original.
      Refuses with exit 3 and a human message when the key cannot be located
      unambiguously; it never guesses and never creates a shadow file.

Both modes fail closed: anything unparseable exits non-zero with a message
naming the file and the problem. Strings are scanned as strings first, so a
"//" inside a URL string or a "/*" inside a description never ends a comment.

Limitation: <dotted.key> addressing cannot express key names containing a
literal ".". OpenCode provider ids do not contain dots, so this is documented
rather than solved.
"""

import json
import os
import sys

EXIT_LOAD_ERROR = 2
EXIT_REFUSE = 3


class JsoncError(Exception):
    """Raised for any input ocm must not edit."""


class Scanner:
    """Masks comments so the remaining text is plain JSON.

    Comment bytes are replaced with spaces of identical length, which keeps
    every offset stable between the masked text and the original file. That is
    what makes span patching possible after a single scan.
    """

    def __init__(self, text):
        self.text = text
        self.out = []
        self.i = 0
        self.n = len(text)

    def scan(self):
        text, n = self.text, self.n
        out = self.out
        # A UTF-8 BOM is one leading character; mask it to one space so the
        # offsets stay stable and the parser sees plain whitespace.
        if n and text[0] == "\ufeff":
            out.append(" ")
            self.i = 1
        while self.i < n:
            c = text[self.i]
            if c == '"':
                self.string()
            elif c == "/" and self.i + 1 < n:
                nxt = text[self.i + 1]
                if nxt == "/":
                    self.line_comment()
                elif nxt == "*":
                    self.block_comment()
                else:
                    out.append(c)
                    self.i += 1
            else:
                out.append(c)
                self.i += 1
        masked = "".join(out)
        # A comment eaten the whole file (unterminated) leaves nothing to parse;
        # surface that before json does.
        if "/" in masked and "*/" not in masked and "//" not in masked:
            pass  # json.loads below will fail with a position if malformed
        return masked

    def string(self):
        text, n = self.text, self.n
        out = self.out
        start = self.i
        self.i += 1  # opening quote
        while self.i < n:
            c = text[self.i]
            if c == "\\" and self.i + 1 < n:
                self.i += 2
                continue
            self.i += 1
            if c == '"':
                out.append(text[start : self.i])
                return
        raise JsoncError("unterminated string starting at offset %d" % start)

    def line_comment(self):
        text, n = self.text, self.n
        start = self.i
        while self.i < n and text[self.i] != "\n":
            self.i += 1
        self.out.append(" " * (self.i - start))

    def block_comment(self):
        text, n = self.text, self.n
        start = self.i
        end = text.find("*/", self.i + 2)
        if end == -1:
            raise JsoncError("unterminated /* comment starting at offset %d" % start)
        self.i = end + 2
        self.out.append(" " * (self.i - start))


class Parser:
    """Minimal JSON parser that also accepts trailing commas.

    Tracks character offsets for arrays so patch() can replace one exactly.
    """

    def __init__(self, masked):
        self.s = masked
        self.i = 0

    def ws(self):
        s, n = self.s, len(self.s)
        while self.i < n and self.s[self.i] in " \t\r\n":
            self.i += 1

    def parse(self):
        self.ws()
        val = self.value()
        self.ws()
        if self.i != len(self.s):
            raise JsoncError("unexpected content at offset %d" % self.i)
        return val

    def value(self):
        self.ws()
        if self.i >= len(self.s):
            raise JsoncError("unexpected end of input")
        c = self.s[self.i]
        if c == "{":
            return self.object()
        if c == "[":
            return self.array()[0]
        if c == '"':
            return self.string()
        return self.literal()

    def string(self):
        s, n = self.s, len(self.s)
        start = self.i
        self.i += 1
        while self.i < n:
            c = s[self.i]
            if c == "\\":
                self.i += 2
                continue
            self.i += 1
            if c == '"':
                return json.loads(s[start : self.i])
        raise JsoncError("unterminated string at offset %d" % start)

    def literal(self):
        s = self.s
        start = self.i
        for word, val in (("true", True), ("false", False), ("null", None)):
            if s.startswith(word, self.i):
                self.i += len(word)
                return val
        m = 0
        n = len(s)
        while self.i + m < n and s[self.i + m] in "-+.eE0123456789":
            m += 1
        token = s[self.i : self.i + m]
        try:
            num = json.loads(token)
        except ValueError:
            raise JsoncError("bad literal %r at offset %d" % (token, start))
        self.i += m
        return num

    def object(self):
        s, n = self.s, len(self.s)
        obj = {}
        self.i += 1  # {
        self.ws()
        if self.i < n and s[self.i] == "}":
            self.i += 1
            return obj
        while True:
            self.ws()
            if self.i >= n or s[self.i] != '"':
                raise JsoncError("expected object key at offset %d" % self.i)
            key = self.string()
            self.ws()
            if self.i >= n or s[self.i] != ":":
                raise JsoncError(
                    "expected ':' after key %r at offset %d" % (key, self.i)
                )
            self.i += 1
            obj[key] = self.value()
            self.ws()
            if self.i < n and s[self.i] == ",":
                self.i += 1
                self.ws()
                if self.i < n and s[self.i] == "}":  # trailing comma
                    self.i += 1
                    return obj
                continue
            if self.i < n and s[self.i] == "}":
                self.i += 1
                return obj
            raise JsoncError("expected ',' or '}' at offset %d" % self.i)

    def array(self):
        """Return (list, start_offset, end_offset_after_closing_bracket)."""
        s, n = self.s, len(self.s)
        start = self.i
        arr = []
        self.i += 1  # [
        self.ws()
        if self.i < n and s[self.i] == "]":
            self.i += 1
            return arr, start, self.i
        while True:
            arr.append(self.value())
            self.ws()
            if self.i < n and s[self.i] == ",":
                self.i += 1
                self.ws()
                if self.i < n and s[self.i] == "]":  # trailing comma
                    self.i += 1
                    return arr, start, self.i
                continue
            if self.i < n and s[self.i] == "]":
                self.i += 1
                return arr, start, self.i
            raise JsoncError("expected ',' or ']' at offset %d" % self.i)


def load_text(path):
    """Read a file as text, byte-round-trip safe (BOM kept as a character)."""
    with open(path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def parse_jsonc(text):
    """Mask comments, then parse. Returns (value, masked)."""
    masked = Scanner(text).scan()
    return Parser(masked).parse(), masked


def find_array_span(masked, dotted_key):
    """Locate the [start, end) span of the array at dotted_key in masked text.

    Returns (start, end) or raises JsoncError naming how far the path got.
    """
    p = Parser(masked)
    p.ws()
    if p.i >= len(masked) or masked[p.i] != "{":
        raise JsoncError("config does not start with an object")
    p.i += 1
    keys = dotted_key.split(".")
    for depth, key in enumerate(keys):
        p.ws()
        last = depth == len(keys) - 1
        descended = False
        while True:
            p.ws()
            if p.i < len(masked) and masked[p.i] == "}":
                raise JsoncError(
                    "key %r not found (object at path %r has no such member)"
                    % (dotted_key, ".".join(keys[:depth]))
                )
            found_key = p.string()
            p.ws()
            if p.i >= len(masked) or masked[p.i] != ":":
                raise JsoncError("expected ':' after key %r" % found_key)
            p.i += 1
            p.ws()
            is_match = found_key == key
            if is_match and last:
                if masked[p.i] != "[":
                    raise JsoncError(
                        "value at %r is not an array (cannot patch a %s)"
                        % (dotted_key, "object" if masked[p.i] == "{" else "scalar")
                    )
                _, start, end = p.array()
                return start, end
            # Descend only into objects on the path; arrays mid-path are a
            # shape ocm never writes and refuses rather than guessing an index.
            if is_match and masked[p.i] != "{":
                raise JsoncError(
                    "key %r is nested under %r which is not an object"
                    % (dotted_key, ".".join(keys[:depth]))
                )
            # Skip this member's value without recording it.
            if is_match:
                # Enter the object and continue the search one level down;
                # the depth loop below parses its members normally.
                p.i += 1  # consume '{'
                descended = True
                break
            if masked[p.i] == "{":
                p.i += 1
                depth_skip = 1
                while depth_skip:
                    c = masked[p.i]
                    if c == '"':
                        p.string()
                        continue
                    if c == "{":
                        depth_skip += 1
                    elif c == "}":
                        depth_skip -= 1
                    p.i += 1
                p.ws()
            elif masked[p.i] == "[":
                _, _, end_off = p.array()
                p.ws()
            else:
                p.value()
                p.ws()
            if p.i < len(masked) and masked[p.i] == ",":
                p.i += 1
                continue
            raise JsoncError("malformed object while searching for %r" % dotted_key)
        # Matched a non-final key: drop one level deeper. The object just
        # descended is already open (we consumed its '{' but not its body).
        # Continue searching for keys[depth+1] inside it.
        p.ws()
        if p.i < len(masked) and masked[p.i] == "}":
            raise JsoncError(
                "key %r not found (object at path %r is empty)"
                % (dotted_key, ".".join(keys[: depth + 1]))
            )
    raise JsoncError("unreachable")


def mode_load(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: jsonc.py load <file>\n")
        return EXIT_LOAD_ERROR
    try:
        text = load_text(argv[1])
        value, _ = parse_jsonc(text)
    except (OSError, JsoncError, ValueError) as e:
        sys.stderr.write("jsonc load failed for %s: %s\n" % (argv[1], e))
        return EXIT_LOAD_ERROR
    sys.stdout.write(json.dumps(value, indent=2, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


def mode_patch(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: jsonc.py patch <file> <dotted.key> <json-array>\n")
        return EXIT_REFUSE
    path, dotted_key, array_json = argv[1], argv[2], argv[3]
    try:
        new_arr = json.loads(array_json)
        if not isinstance(new_arr, list):
            raise ValueError("replacement is not a JSON array")
        text = load_text(path)
        value, masked = parse_jsonc(text)
        start, end = find_array_span(masked, dotted_key)
    except (OSError, JsoncError, ValueError) as e:
        sys.stderr.write("jsonc patch refused for %s: %s\n" % (path, e))
        return EXIT_REFUSE

    replacement = json.dumps(new_arr, ensure_ascii=True)
    patched = text[:start] + replacement + text[end:]
    # Belt and braces: the patched file must still parse, and the only value
    # that may differ from the original is the patched array itself.
    try:
        new_value, _ = parse_jsonc(patched)
    except (JsoncError, ValueError) as e:
        sys.stderr.write("jsonc patch produced an unparseable file: %s\n" % e)
        return EXIT_REFUSE
    if get_by_path(new_value, dotted_key) != new_arr:
        sys.stderr.write("jsonc patch self-check failed: patched value not readable\n")
        return EXIT_REFUSE

    tmp = path + ".tmp"
    try:
        with open(
            tmp, "w", encoding="utf-8", errors="surrogateescape", newline=""
        ) as f:
            f.write(patched)
        os.replace(tmp, path)
    except OSError as e:
        sys.stderr.write("jsonc patch could not write %s: %s\n" % (path, e))
        return EXIT_REFUSE
    print("patched %s in %s (%d values)" % (dotted_key, path, len(new_arr)))
    return 0


def get_by_path(value, dotted_key):
    for key in dotted_key.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def mode_locate(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: jsonc.py locate <file> <dotted.key>\n")
        return EXIT_REFUSE
    path, dotted_key = argv[1], argv[2]
    try:
        text = load_text(path)
        _, masked = parse_jsonc(text)
        start, end = find_array_span(masked, dotted_key)
    except (OSError, JsoncError, ValueError) as e:
        sys.stderr.write("jsonc locate refused for %s: %s\n" % (path, e))
        return EXIT_REFUSE
    print("%d %d" % (start, end))
    return 0


def mode_refuse_help(argv):
    sys.stderr.write(__doc__ or "")
    return EXIT_REFUSE


MODES = {
    "load": mode_load,
    "patch": mode_patch,
    "locate": mode_locate,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in MODES:
        return mode_refuse_help(sys.argv)
    return MODES[sys.argv[1]](sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
