#!/usr/bin/env python3
"""Fails if a Markdown file links to a file or #heading in this repository that does not exist."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def anchors(text: str) -> set[str]:
    return {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-")
            for h in re.findall(r"^#+\s+(.*)$", text, re.M)}


def main() -> int:
    files = [p for p in ROOT.rglob("*.md") if ".build" not in p.parts and "build" not in p.parts]
    broken = []
    for md in files:
        for target in re.findall(r"\]\(([^)\s]+)\)", md.read_text()):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            path, _, fragment = target.partition("#")
            file = (md.parent / path).resolve() if path else md.resolve()
            if not file.exists():
                broken.append(f"{md.relative_to(ROOT)}: {target} (no such file)")
            elif fragment and file.suffix == ".md" and fragment not in anchors(file.read_text()):
                broken.append(f"{md.relative_to(ROOT)}: {target} (no such heading)")
    print("\n".join(broken) or f"Links OK in {len(files)} Markdown files.")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
