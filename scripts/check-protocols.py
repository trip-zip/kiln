#!/usr/bin/env python3
"""Compare generated protocol tables with wayland-scanner without compiling C."""

import difflib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent


def entries(pattern, body):
    matches = list(re.finditer(pattern, body))
    if re.sub(pattern, "", body).strip():
        raise ValueError(f"unparsed table text: {body}")
    return [match.groups() for match in matches]


def c_tables(text):
    types = {}
    for name, body in re.findall(
        r"static const struct wl_interface \*(\w+)\[\] = \{(.*?)\};", text, re.S
    ):
        types[name] = [
            ref or None
            for (ref,) in entries(r"\s*(?:&(\w+)_interface|NULL),", body)
        ]
    messages = {}
    for name, body in re.findall(
        r"static const struct wl_message (\w+)\[\] = \{(.*?)\};", text, re.S
    ):
        messages[name] = []
        for member, signature, pool, offset in entries(
            r'\s*\{ "(\w+)", "([0-9?iufsonah]*)", (\w+) \+ (\d+) \},', body
        ):
            count = len(re.sub(r"[0-9?]", "", signature))
            refs = types[pool][int(offset):int(offset) + count]
            assert len(refs) == count
            messages[name].append((member, signature, refs))
    interfaces = {}
    for name, body in re.findall(
        r"const struct wl_interface (\w+)_interface = \{(.*?)\};", text, re.S
    ):
        [(wire_name, version, requests, request_table, events, event_table)] = entries(
            r'\s*"(\w+)", (\d+),\s*(\d+), (\w+),\s*(\d+), (\w+),\s*', body
        )
        assert name == wire_name
        methods = messages.get(request_table, [])
        signals = messages.get(event_table, [])
        assert len(methods) == int(requests) and len(signals) == int(events)
        assert request_table in messages or request_table == "NULL"
        assert event_table in messages or event_table == "NULL"
        interfaces[name] = (int(version), methods, signals)
    return interfaces


def odin_tables(text):
    types = {
        name: [None] * int(count)
        for name, count in re.findall(r"(\w+): \[(\d+)\]\^wl.Interface", text)
    }
    for name, index, ref in re.findall(r"(\w+)_types\[(\d+)\] = &(\w+)", text):
        types[name + "_types"][int(index)] = ref
    messages = {}
    for name, size, body in re.findall(
        r"(\w+): \[(\d+)\]wl.Message = \{(.*?)\n\}", text, re.S
    ):
        messages[name] = []
        for member, signature, pool in entries(
            r'\s*\{"(\w+)", "([0-9?iufsonah]*)", &(\w+)\[0\]\},', body
        ):
            count = len(re.sub(r"[0-9?]", "", signature))
            assert len(types[pool]) == max(1, count)
            messages[name].append((member, signature, types[pool][:count]))
        assert len(messages[name]) == int(size)
    interfaces = {}
    for name, body in re.findall(r"(\w+): wl.Interface = \{(.*?)\n\}", text, re.S):
        [(wire_name, version, requests, request_table, events, event_table)] = entries(
            r'\s*"(\w+)", (\d+),\s*(\d+), (nil|&\w+\[0\]),'
            r'\s*(\d+), (nil|&\w+\[0\]),\s*', body
        )
        assert name == wire_name
        methods = [] if request_table == "nil" else messages[request_table[1:-3]]
        signals = [] if event_table == "nil" else messages[event_table[1:-3]]
        assert len(methods) == int(requests) and len(signals) == int(events)
        interfaces[name] = (int(version), methods, signals)
    return interfaces


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix="kiln-protocols-") as directory:
        scratch = Path(directory)
        for xml in sorted((ROOT / "protocols/xml").glob("*.xml")):
            source = xml.relative_to(ROOT).as_posix()
            generated = scratch / f"{xml.stem}.odin"
            core = xml.name == "wayland.xml"
            subprocess.run(
                [str(ROOT / "build/kiln-scanner"), *(["--export-c"] if core else []),
                 source, str(generated)], cwd=ROOT, check=True
            )
            checked_in = ROOT / "protocols" / generated.name
            assert generated.read_bytes() == checked_in.read_bytes(), f"run make protocols: {source}"
            own = generated.read_text()
            reference = scratch / f"{xml.stem}.txt"
            subprocess.run(["wayland-scanner", "private-code", str(xml), str(reference)], check=True)
            got, want = odin_tables(own), c_tables(reference.read_text())
            names = {node.attrib["name"] for node in ET.parse(xml).getroot().findall("interface")}
            assert set(got) == set(want) == names, source
            exports = set(re.findall(r'@\(export, link_name = "(\w+)_interface"\)', own))
            assert exports == (names if core else set()), source
            if got != want:
                diff = "".join(difflib.unified_diff(
                    json.dumps(want, indent=2).splitlines(True),
                    json.dumps(got, indent=2).splitlines(True),
                    fromfile="wayland-scanner", tofile="kiln-scanner",
                ))
                raise AssertionError(f"{source}\n{diff}")
            count += 1
            print(f"PASS {xml.name}: reproducible; {len(names)} interfaces match wayland-scanner")
    assert count > 0, "no vendored protocols found"


if __name__ == "__main__":
    main()
