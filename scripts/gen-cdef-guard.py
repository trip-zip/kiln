#!/usr/bin/env python3
"""Generate the cdef-sync guard from lua/kiln/cffi.lua (shard #111, spec s6 M17).

A ffi.cdef is an unchecked assertion about C's memory layout and calling
convention. Nothing in LuaJIT compares it to the header it names, so a cdef
that drifts from the C does not fail: it corrupts, at runtime, silently.

This emits a C translation unit that makes the compiler do the comparison.
Every declaration between the CDEF-BEGIN and CDEF-END markers in cffi.lua is
compiled alongside core.h:

  * functions and forward declarations go through verbatim, so a signature that
    disagrees with the real one is "conflicting types" at build time;
  * a struct definition is copied under a kiln_cdef_ prefix (C forbids the
    verbatim redefinition) and pinned to the real struct with _Static_asserts on
    sizeof and on every field's offsetof;
  * a /* CDEF-INCLUDE "x.h" */ line names a header the comparison needs. core.h
    is always included; a struct that another header owns (struct ui_hit, ui.h;
    the Clay declaration chain, clay.h) has to be visible here or its offsetof
    asserts cannot be written.
  * a /* CDEF-ENUM Clay_Foo */ line names an enum type the cdef stands in for.
    LuaJIT's FFI has no syntax for clay.h's packed enums (one byte each), so
    those fields are cdef'd as uint8_t; this pins the substitution with a sizeof
    assert, so an enum that stops being one byte fails the build here instead of
    silently shifting every field after it.

Usage: gen-cdef-guard.py <cffi.lua> <out.c>
"""

import re
import sys

BEGIN_END = re.compile(r"/\* CDEF-BEGIN.*?\*/(.*?)/\* CDEF-END \*/", re.S)
INCLUDE = re.compile(r"/\*\s*CDEF-INCLUDE\s+(\"[^\"]+\"|<[^>]+>)\s*\*/")
ENUM_PIN = re.compile(r"/\*\s*CDEF-ENUM\s+(\w+)\s*\*/")
STRUCT_HEAD = re.compile(r"\bstruct\s+(\w+)\s*\{")
FIELD_NAME = re.compile(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*$")


def find_structs(block):
    """Every top-level `struct NAME { ... };` in the block, brace-matched.

    Brace matching rather than a regex because a struct body can nest: the
    sizing axis carries an anonymous union, and a `[^{}]*` body cannot see it.
    Returns (name, body, start, end) with end just past the trailing semicolon.
    """
    found = []
    for head in STRUCT_HEAD.finditer(block):
        open_at = block.index("{", head.start())
        depth, i = 0, open_at
        while i < len(block):
            if block[i] == "{":
                depth += 1
            elif block[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if depth != 0:
            sys.exit("gen-cdef-guard: unbalanced braces in struct " + head.group(1))
        close_at = i
        semi = block.index(";", close_at)
        if block[close_at + 1:semi].strip():
            continue  # `} name;` is a member, not a top-level definition
        if any(start < head.start() < end for _, _, start, end in found):
            continue  # nested inside a struct already collected
        found.append((head.group(1), block[open_at + 1:close_at],
                      head.start(), semi + 1))
    return found


def field_names(body):
    """The declared field names of a struct body, in order.

    A nested `union { ... } name;` counts as the one field it declares: its own
    members share an offset by definition, and the size of the union is pinned
    by the containing struct's sizeof and by the offsetof of the field after it.
    """
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    names = []
    while True:
        brace = body.find("{")
        if brace < 0:
            break
        depth, i = 0, brace
        while i < len(body):
            if body[i] == "{":
                depth += 1
            elif body[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        semi = body.index(";", i)
        # Replace the whole nested block with just its member declaration.
        head = body.rfind(";", 0, brace) + 1
        body = body[:head] + body[i + 1:semi] + ";" + body[semi + 1:]
    for decl in body.split(";"):
        decl = decl.strip()
        if not decl:
            continue
        for part in decl.split(","):
            match = FIELD_NAME.search(part.strip())
            if match is None:
                sys.exit("gen-cdef-guard: cannot read a field name from %r" % part)
            names.append(match.group(1))
    return names


def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path) as f:
        source = f.read()

    found = BEGIN_END.search(source)
    if found is None:
        sys.exit("gen-cdef-guard: no CDEF-BEGIN/CDEF-END block in " + src_path)
    block = found.group(1)
    # The refusal reads the declarations, not the prose: "packed enum" in a
    # comment is a description, and the CDEF-ENUM directives are comments too.
    if re.search(r"\benum\b", re.sub(r"/\*.*?\*/", " ", block, flags=re.S)):
        sys.exit("gen-cdef-guard: enums are not pinned yet; cdef the field as "
                 "the integer type it packs to and name it in a CDEF-ENUM line, "
                 "or teach this script before cdef'ing an enum outright")

    structs = find_structs(block)
    asserts = []
    for name, body, _, _ in structs:
        asserts.append("struct kiln_cdef_%s {%s};" % (name, body))
        asserts.append(
            '_Static_assert(sizeof(struct kiln_cdef_%s) == sizeof(struct %s),\n'
            '\t"cdef drift: struct %s changed size");' % (name, name, name))
        for field in field_names(body):
            asserts.append(
                '_Static_assert(offsetof(struct kiln_cdef_%s, %s)\n'
                '\t== offsetof(struct %s, %s),\n'
                '\t"cdef drift: struct %s field %s moved");'
                % (name, field, name, field, name, field))
    for name in ENUM_PIN.findall(block):
        asserts.append(
            '_Static_assert(sizeof(%s) == 1,\n'
            '\t"cdef drift: %s no longer packs to one byte");' % (name, name))

    verbatim = block
    for _, _, start, end in reversed(structs):
        verbatim = verbatim[:start] + verbatim[end:]
    verbatim = ENUM_PIN.sub("", INCLUDE.sub("", verbatim)).strip()
    extra = "".join("#include %s\n" % h for h in INCLUDE.findall(block))

    with open(out_path, "w") as f:
        f.write("/* GENERATED by scripts/gen-cdef-guard.py from %s. Do not edit.\n"
                " * The cdef in that file, compiled against the real headers: a\n"
                " * signature or layout that drifts fails the build here. */\n"
                % src_path)
        f.write("#include <stdbool.h>\n#include <stddef.h>\n"
                "#include <stdint.h>\n#include \"core.h\"\n%s\n" % extra)
        f.write(verbatim + "\n")
        if asserts:
            f.write("\n" + "\n\n".join(asserts) + "\n")


main()
