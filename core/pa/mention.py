"""`@` targets in a note: the user names where it should go.

The quick note inserts `@[[01-projects/alpha/README]]` (a note, without .md) or
`@[[01-projects/alpha/]]` (a folder). Written by hand, `@alpha` matches a note's
file name, path or title, or a folder name or path, exactly (case-insensitive);
`@alpha/` only folders. Only indexed notes and their folders resolve, so ignored
paths and the assistant folder never do.
"""

import re
from pathlib import PurePosixPath
from typing import Any, Dict, List, Set, Tuple

LINKED = re.compile(r"@\[\[([^\]\n]+)\]\]")
BARE = re.compile(r"(?:^|(?<=[\s(]))@([^\s@\[\]()]+)")


def folders(notes: Dict[str, Dict[str, Any]]) -> Set[str]:
    out: Set[str] = set()
    for rel in notes:
        for parent in PurePosixPath(rel).parents:
            if str(parent) != ".":
                out.add(parent.as_posix())
    return out


def resolve(text: str, notes: Dict[str, Dict[str, Any]]) -> List[Tuple[str, str]]:
    """[(kind, path)] in order of appearance, kind "note" or "folder"; unknown names are skipped."""
    dirs = folders(notes)
    found: List[Tuple[str, str]] = []

    def add(kind: str, path: str) -> None:
        if (kind, path) not in found:
            found.append((kind, path))

    for m in LINKED.finditer(text):
        target = m.group(1).strip()
        if target.endswith("/"):
            if target.rstrip("/") in dirs:
                add("folder", target.rstrip("/"))
            continue
        rel = target if target.endswith(".md") else target + ".md"
        if rel in notes:
            add("note", rel)
        elif target in dirs:
            add("folder", target)
    for m in BARE.finditer(LINKED.sub(" ", text)):
        name = m.group(1).rstrip(".,:;!?").lower()
        folder_only = name.endswith("/")
        name = name.rstrip("/")
        if not name:
            continue
        for rel in [] if folder_only else sorted(notes):
            if name in (PurePosixPath(rel).stem.lower(), rel[:-3].lower(), str(notes[rel].get("title", "")).lower()):
                add("note", rel)
        for d in sorted(dirs):
            if name in (PurePosixPath(d).name.lower(), d.lower()):
                add("folder", d)
    return found
