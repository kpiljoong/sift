"""Splitting the free-form inbox into blocks and removing processed blocks.

A block is a run of non-blank lines; a markdown heading also starts a new block.
YAML frontmatter at the top of the file is never treated as a block.
"""

import hashlib
import re
from dataclasses import dataclass
from typing import Iterable, List, Set, Tuple


HEADING = re.compile(r"^#{1,6}\s")


@dataclass
class Block:
    id: str
    text: str
    start: int  # first line index (inclusive)
    end: int  # last line index (exclusive)


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def block_id(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]


def _frontmatter_end(lines: List[str]) -> int:
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return i + 1
    return 0


def split_blocks(content: str) -> List[Block]:
    lines = content.split("\n")
    blocks: List[Block] = []
    start = None

    def close(end: int) -> None:
        text = "\n".join(lines[start:end])
        blocks.append(Block(block_id(text), text, start, end))

    for i in range(_frontmatter_end(lines), len(lines)):
        line = lines[i]
        if not line.strip():
            if start is not None:
                close(i)
                start = None
            continue
        if HEADING.match(line) and start is not None:
            close(i)
            start = None
        if start is None:
            start = i
    if start is not None:
        close(len(lines))
    return blocks


def remove_blocks(content: str, texts: Iterable[str]) -> Tuple[str, Set[str]]:
    """Remove blocks whose text matches exactly. Returns (new content, removed texts).

    Each requested text removes at most one block. Blank lines directly after a
    removed block are dropped too so gaps don't accumulate.
    """
    wanted = list(texts)
    lines = content.split("\n")
    drop: Set[int] = set()
    removed: Set[str] = set()
    for block in split_blocks(content):
        if block.text in wanted:
            wanted.remove(block.text)
            removed.add(block.text)
            drop.update(range(block.start, block.end))
            j = block.end
            while j < len(lines) and not lines[j].strip():
                drop.add(j)
                j += 1
    kept = [line for i, line in enumerate(lines) if i not in drop]
    new = "\n".join(kept)
    if new.strip() == "":
        new = "\n".join(lines[: _frontmatter_end(lines)])
        new = new + "\n" if new else ""
    elif content.endswith("\n") and not new.endswith("\n"):
        new += "\n"
    return new, removed
