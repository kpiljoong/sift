"""Local vault index and search.

The index stores, per note: title, a few frontmatter properties, headings and a
short snippet. It is refreshed incrementally by mtime and saved outside the
vault. Search uses character bigrams so Korean words with particles
("tramio를") still match their stem. Excluded paths are never indexed, so they
can never reach the model.
"""

import json
import math
import os
import re
import time
from collections import Counter
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Tuple

from .config import Config, support_dir
from .vault import _is_ignored, ignore_list

KEEP_PROPS = ("project", "type", "tags", "categories", "status", "aliases", "source", "confidence")
HEADING = re.compile(r"^(#{1,3})\s+(.+)")
WORD = re.compile(r"[0-9A-Za-zÀ-ɏ぀-ヿ㐀-鿿가-힣]+")


def index_path() -> Path:
    return support_dir() / "index.json"


# ---------- parsing ----------


def _scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def parse_frontmatter(text: str) -> Tuple[Dict[str, Any], str]:
    """Tiny YAML subset: `key: value`, `key: [a, b]` and `key:` + `- item` lists."""
    if not text.startswith("---"):
        return {}, text
    lines = text.split("\n")
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return {}, text
    props: Dict[str, Any] = {}
    key = None
    for line in lines[1:end]:
        item = re.match(r"^\s*-\s+(.*)$", line)
        if item and key:
            if not isinstance(props.get(key), list):
                props[key] = []
            props[key].append(_scalar(item.group(1)))
            continue
        kv = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if kv:
            key, value = kv.group(1), kv.group(2).strip()
            if value.startswith("[") and value.endswith("]"):
                props[key] = [_scalar(v) for v in value[1:-1].split(",") if v.strip()]
            else:
                props[key] = _scalar(value) if value else None
    return props, "\n".join(lines[end + 1 :])


def parse_note(rel: str, text: str) -> Dict[str, Any]:
    props, body = parse_frontmatter(text)
    title = PurePosixPath(rel).stem
    headings: List[str] = []
    rest: List[str] = []
    for line in body.split("\n"):
        m = HEADING.match(line)
        if m:
            if m.group(1) == "#" and title == PurePosixPath(rel).stem:
                title = m.group(2).strip()
            elif len(headings) < 8:
                headings.append(m.group(2).strip())
        elif line.strip():
            rest.append(line.strip())
    snippet = " ".join(rest)[:300]
    return {
        "title": title,
        "props": {k: props[k] for k in KEEP_PROPS if props.get(k) not in (None, "", [])},
        "headings": headings,
        "snippet": snippet,
    }


# ---------- index maintenance ----------


def _walk(cfg: Config):
    root = cfg.vault_path
    patterns = ignore_list(cfg) + [cfg.assistant_dir]
    inbox = PurePosixPath(cfg.inbox)
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = PurePosixPath(Path(dirpath).relative_to(root).as_posix())
        base = PurePosixPath() if str(rel_dir) == "." else rel_dir
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and not _is_ignored(base / d, patterns)]
        for name in filenames:
            rel = base / name
            if name.endswith(".md") and rel != inbox and not _is_ignored(rel, patterns):
                yield rel.as_posix(), Path(dirpath) / name


def update_index(cfg: Config) -> Dict[str, Dict[str, Any]]:
    path = index_path()
    try:
        old = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except ValueError:
        old = {}
    if old.get("vault") != str(cfg.vault_path):
        old = {}
    notes = old.get("notes", {})
    fresh: Dict[str, Dict[str, Any]] = {}
    changed = False
    for rel, full in _walk(cfg):
        try:
            mtime = full.stat().st_mtime
        except OSError:
            continue
        cached = notes.get(rel)
        if cached and cached.get("mtime") == mtime:
            fresh[rel] = cached
            continue
        try:
            text = full.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        fresh[rel] = dict(parse_note(rel, text), mtime=mtime)
        changed = True
    if changed or set(fresh) != set(notes):
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"vault": str(cfg.vault_path), "notes": fresh}, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)
    return fresh


# ---------- search ----------


def grams(text: str) -> set:
    out = set()
    for word in WORD.findall(text.lower()):
        if len(word) == 1:
            out.add(word)
        else:
            out.update(word[i : i + 2] for i in range(len(word) - 1))
    return out


def _props_text(props: Dict[str, Any]) -> str:
    return " ".join(" ".join(v) if isinstance(v, list) else str(v) for v in props.values())


class Searcher:
    def __init__(self, notes: Dict[str, Dict[str, Any]]):
        self.notes = notes
        self.head: Dict[str, set] = {}
        self.head_text: Dict[str, str] = {}
        self.body: Dict[str, set] = {}
        df: Counter = Counter()
        for rel, n in notes.items():
            project = n["props"].get("project") or ""
            head = grams(f"{rel.replace('/', ' ')} {n['title']} {project}")
            body = grams(f"{' '.join(n['headings'])} {n['snippet']} {_props_text(n['props'])}") | head
            self.head[rel], self.body[rel] = head, body
            self.head_text[rel] = f"{rel} {n['title']} {project}".lower()
            df.update(body)
        total = max(len(notes), 1)
        self.idf = {g: math.log(1 + total / c) for g, c in df.items()}

    def search(self, query: str, k: int = 8) -> List[str]:
        q = grams(query)
        words = {w for w in WORD.findall(query.lower()) if len(w) >= (3 if w.isascii() else 2)}
        now = time.time()
        scored = []
        for rel, body in self.body.items():
            hits = q & body
            if not hits:
                continue
            head = self.head[rel]
            score = sum(self.idf[g] * (2.0 if g in head else 1.0) for g in hits)
            score /= len(body) ** 0.25
            score += 10 * sum(1 for w in words if w in self.head_text[rel])  # named project/note
            age_days = (now - self.notes[rel].get("mtime", 0)) / 86400
            score *= 1.5 if age_days < 90 else 1.2 if age_days < 365 else 1.0  # active notes first
            if "archive" in rel.lower():
                score *= 0.5
            scored.append((score, rel))
        scored.sort(reverse=True)
        return [rel for _, rel in scored[:k]]

    def describe(self, rel: str) -> str:
        n = self.notes[rel]
        props = ", ".join(
            f"{k}={'/'.join(v) if isinstance(v, list) else v}" for k, v in n["props"].items()
        )
        parts = [f"`{rel}`", n["title"]]
        if props:
            parts.append(props)
        if n["headings"]:
            parts.append("headings: " + " / ".join(n["headings"][:5]))
        if n["snippet"]:
            parts.append("summary: " + n["snippet"][:160])
        return " | ".join(parts)
