#!/usr/bin/env python3
"""Sandboxed document -> Markdown converter.

Runs markitdown (Microsoft, MIT) INSIDE the container against a file staged in
/work, so any PDF / DOCX / PPTX / XLSX / HTML / CSV / JSON / XML / EPub / image
the sandbox fetched (or that was dropped into --work) becomes clean Markdown
without ever leaving the isolated environment or hitting a cloud API.

Input file path comes in via CONVERT_FILE (resolved inside /work); the Markdown
is written next to it as <stem>.md, and a JSON summary is printed on stdout.

This lives in its own venv (/opt/convertvenv) so markitdown's large dependency
set can never regress the pinned recipe runner.
"""
import json
import os
import sys

WORK_DIR = os.environ.get("WORK_DIR", "/work")


def _resolve(name: str) -> str:
    # Confine the input to /work, mirroring driver.py's _resolve_shot: a path
    # that escapes the work dir is collapsed to its basename inside it.
    p = name if os.path.isabs(name) else os.path.join(WORK_DIR, name)
    real = os.path.realpath(p)
    work = os.path.realpath(WORK_DIR)
    if os.path.commonpath([real, work]) != work:
        real = os.path.join(work, os.path.basename(name))
    return real


def main() -> int:
    name = os.environ.get("CONVERT_FILE", "")
    if not name:
        print(json.dumps({"ok": False, "error": "CONVERT_FILE not set"}))
        return 2
    src = _resolve(name)
    if not os.path.exists(src):
        print(json.dumps({"ok": False, "error": f"file not found in /work: {name}"}))
        return 2
    try:
        from markitdown import MarkItDown
        md = MarkItDown(enable_plugins=False)
        result = md.convert(src)
        text = result.text_content or ""
    except Exception as e:  # noqa: BLE001 - surface any conversion failure as structured JSON
        print(json.dumps({"ok": False, "file": os.path.basename(src), "error": str(e)}))
        return 1
    out = os.path.splitext(src)[0] + ".md"
    try:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "file": os.path.basename(src), "error": f"write failed: {e}"}))
        return 1
    print(json.dumps({"ok": True, "file": os.path.basename(src),
                      "out": out, "chars": len(text), "markdown": text}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
