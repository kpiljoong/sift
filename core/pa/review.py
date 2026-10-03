"""Items waiting for the user's check, and re-sort bookkeeping.

An item needs review while it sits in `review/` or one of its lines still carries the
#assistant/review tag. Removing the tag in the vault (or ✓ in the menu bar) settles it;
a re-sort settles the old entry and marks its open todos as moved.
"""
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import Config
from .i18n import tr

TAG = "#assistant/review"
LIMIT = 50


def anchors(entry: Dict[str, Any]) -> List[str]:
    """Archive-link anchors of an entry, as they appear in its result lines (`#<stamp> <id>|`)."""
    stamp = str(entry.get("time", "")).replace(":", "")
    ids = [str(i) for i in entry.get("ids") or [entry.get("id")] if i]
    return [f"#{stamp} {i}|" for i in ids]


def key(entry: Dict[str, Any]) -> str:
    return f"{entry.get('id', '')}-{entry.get('time', '')}"  # same as the menu bar's item id


def in_review_dir(cfg: Config, target: str) -> bool:
    return target.startswith(f"{cfg.assistant_dir}/review/")


def _lines(cfg: Config, target: str) -> Optional[List[str]]:
    path = cfg.vault_path / target
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None


def is_open(cfg: Config, entry: Dict[str, Any]) -> bool:
    marks = anchors(entry)
    for target in entry.get("targets") or []:
        if in_review_dir(cfg, target):
            if (cfg.vault_path / target).exists():
                return True
            continue
        for line in _lines(cfg, target) or []:
            if TAG in line and any(m in line for m in marks):
                return True
    return False


def track(state: Dict[str, Any], entry: Dict[str, Any]) -> None:
    state["review"] = (state["review"] + [entry])[-LIMIT:]


def settle(state: Dict[str, Any], entry: Dict[str, Any]) -> None:
    state["review"] = [e for e in state["review"] if key(e) != key(entry)]


def open_items(cfg: Config, state: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Open review items, newest first. Ones the user settled in the vault are dropped."""
    if not state.get("review_seeded"):  # installs from before the list: start from the history
        state["review"] = [e for e in state["history"] if is_open(cfg, e)][-LIMIT:]
        state["review_seeded"] = True
    state["review"] = [e for e in state["review"] if is_open(cfg, e)]
    return list(reversed(state["review"]))


def mark_moved(cfg: Config, old: Dict[str, Any], new_targets: List[str]) -> int:
    """Append "↪ moved [[new]]" to the old entry's open todo/calendar lines.

    The one in-place edit besides the inbox move: only unchecked lines carrying the old
    entry's archive link get a suffix; nothing is removed or rewritten.
    """
    marks = anchors(old)
    count = 0
    for target in old.get("targets") or []:
        if in_review_dir(cfg, target):
            continue
        where = next((t for t in new_targets if not in_review_dir(cfg, t) and t != target), None)
        suffix = f" ↪ {tr('moved', '옮김')}"
        if where:
            suffix += f" [[{where[:-3] if where.endswith('.md') else where}]]"
        lines = _lines(cfg, target)
        if lines is None:
            continue
        changed = False
        for n, line in enumerate(lines):
            if line.lstrip().startswith("- [ ]") and any(m in line for m in marks) and "↪" not in line:
                lines[n] = line + suffix
                changed = True
                count += 1
        if changed:
            path: Path = cfg.vault_path / target
            text = path.read_text(encoding="utf-8")
            tmp = path.with_name(f".{path.name}.sift-tmp")
            tmp.write_text("\n".join(lines) + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
            tmp.replace(path)
    return count
