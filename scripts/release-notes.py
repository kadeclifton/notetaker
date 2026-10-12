#!/usr/bin/env python3
"""Notes for a release: that version's list from CHANGELOG.md, then docs/INSTALL.md.

    python3 scripts/release-notes.py v0.2.3 > notes.md

A pre-release tag (v0.2.3-beta.2) uses the 0.2.3 list. With no list for the version, the notes are
the install guide alone. Murmur's update menu shows the bullets under the "What's new" heading.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def section(changelog: str, version: str) -> str:
    lines, inside = [], False
    for line in changelog.splitlines():
        if line.startswith("## "):
            if inside:
                break
            words = line[3:].split()
            inside = bool(words) and words[0] == version
            continue
        if inside:
            lines.append(line)
    return "\n".join(lines).strip()


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: release-notes.py <tag>")
    tag = sys.argv[1]
    version = re.sub(r"^[vV]", "", tag).split("-", 1)[0]
    install = (ROOT / "docs" / "INSTALL.md").read_text()
    changelog = ROOT / "CHANGELOG.md"
    changes = section(changelog.read_text(), version) if changelog.exists() else ""
    if not changes:
        sys.stdout.write(install)
        return
    beta = " (beta)" if "-" in tag else ""
    sys.stdout.write(f"# What's new in {version}{beta}\n\n{changes}\n\n---\n\n{install}")


if __name__ == "__main__":
    main()
