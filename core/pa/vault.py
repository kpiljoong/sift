"""Vault access. The only write operations that exist are create-new and append.

There is deliberately no delete or overwrite helper for vault notes. The one
exception to append-only is rewriting the inbox, which lives in engine.py and is
guarded by a content-hash check.
"""

import os
import re
from pathlib import Path, PurePosixPath
from typing import List, Optional

from .config import Config
from .i18n import set_language, tr

DEFAULTS_DIR = Path(__file__).parent / "defaults"  # en/ and ko/ hold the same files
RULE_FILES = ["todo-format.md", "placement.md", "calendar-format.md", "frontmatter.md", "corrections.md"]


class UnsafePath(Exception):
    pass


def ignore_list(cfg: Config) -> List[str]:
    patterns = list(cfg.exclude)
    ignore_file = cfg.assistant_path / ".assistantignore"
    if ignore_file.exists():
        for line in ignore_file.read_text(encoding="utf-8").splitlines():
            line = line.strip().strip("/")
            if line and not line.startswith("#"):
                patterns.append(line)
    return patterns


def _is_ignored(rel: PurePosixPath, patterns: List[str]) -> bool:
    for pattern in patterns:
        p = PurePosixPath(pattern)
        if rel == p or p in rel.parents or (len(p.parts) == 1 and p.name in rel.parts):
            return True
    return False


def resolve_note(cfg: Config, rel: str) -> Path:
    """Validate an AI-proposed note path and return its absolute path."""
    if not rel or rel.startswith("/") or "\\" in rel:
        raise UnsafePath(f"not a vault-relative path: {rel!r}")
    posix = PurePosixPath(rel)
    if any(part in ("", ".", "..") for part in posix.parts):
        raise UnsafePath(f"path traversal: {rel!r}")
    if posix.suffix != ".md":
        raise UnsafePath(f"only .md notes may be written: {rel!r}")
    if posix.parts[0].startswith("."):
        raise UnsafePath(f"hidden folder: {rel!r}")
    if posix == PurePosixPath(cfg.inbox):
        raise UnsafePath("the inbox cannot be a target")
    if PurePosixPath(cfg.assistant_dir) in posix.parents:
        raise UnsafePath(f"assistant folder is managed by the engine: {rel!r}")
    if _is_ignored(posix, ignore_list(cfg)):
        raise UnsafePath(f"path is excluded: {rel!r}")
    full = cfg.vault_path / posix
    if cfg.vault_path.resolve() not in full.resolve().parents:  # also catches symlinks
        raise UnsafePath(f"escapes the vault: {rel!r}")
    return full


def _folder_key(name: str) -> str:
    return re.sub(r"[\s_.-]+", "", name.lower()).rstrip("s")


def reuse_similar_folder(cfg: Config, rel: str) -> str:
    """A note planned in a folder that doesn't exist yet goes into an existing sibling folder
    with nearly the same name instead (agent-note → agent-notes, Tramio → tramio)."""
    parts = PurePosixPath(rel).parts
    base = cfg.vault_path
    for i, part in enumerate(parts[:-1]):
        if (base / part).is_dir():
            base = base / part
            continue
        if base.is_dir():
            for existing in sorted(base.iterdir()):
                if existing.is_dir() and not existing.name.startswith(".") and _folder_key(existing.name) == _folder_key(part):
                    return str(PurePosixPath(*parts[:i], existing.name, *parts[i + 1:]))
        break
    return rel


def new_project_folder(cfg: Config, path: Path) -> Optional[str]:
    """The new top-level or second-level folder (a new project, area or topic, like
    `01-projects/tramio`) that writing `path` would create, vault-relative. Subfolders of
    existing ones (`01-projects/alpha/meetings`) don't count."""
    missing = None
    for parent in path.parents:
        if parent == cfg.vault_path or cfg.vault_path not in parent.parents:
            break
        if not parent.exists():
            missing = parent
    if missing is None:
        return None
    rel = missing.relative_to(cfg.vault_path)
    return rel.as_posix() if len(rel.parts) <= 2 else None


def append(path: Path, text: str) -> None:
    """Append text as a new paragraph. Creates the file (and folders) if missing."""
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    if existing and not existing.endswith("\n\n"):
        sep = "\n" if existing.endswith("\n") else "\n\n"
    else:
        sep = ""
    with path.open("a", encoding="utf-8") as fh:
        fh.write(sep + text.rstrip("\n") + "\n")


def append_line(path: Path, line: str) -> None:
    """Append a single line with no paragraph spacing (used for logs)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    sep = "\n" if existing and not existing.endswith("\n") else ""
    with path.open("a", encoding="utf-8") as fh:
        fh.write(sep + line.rstrip("\n") + "\n")


def create(path: Path, text: str) -> None:
    """Create a new note. Fails instead of overwriting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as fh:
        fh.write(text.rstrip("\n") + "\n")


def init_assistant_dir(cfg: Config) -> None:
    """Create what's missing, in the configured language. Existing files are never touched."""
    set_language(cfg.language)
    root = cfg.assistant_path
    defaults = DEFAULTS_DIR / cfg.language
    for sub in ("inbox-archive", "backup", "review", "rules", "log"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    for name in RULE_FILES:
        target = root / "rules" / name
        if not target.exists():
            create(target, (defaults / name).read_text(encoding="utf-8"))
    for name, text in (
        ("todo.md", "# Todo\n"),
        ("calendar-queue.md", tr("# Calendar queue\n", "# 일정 등록 대기\n")),
        (".assistantignore", tr("# Vault-relative paths the AI must never read or write (one per line)\n",
                                "# AI가 읽거나 쓰면 안 되는 vault 상대 경로 (한 줄에 하나)\n")),
    ):
        if not (root / name).exists():
            create(root / name, text)
    base = root / "assistant.base"
    if not base.exists():
        create(base, (defaults / "assistant.base").read_text(encoding="utf-8"))


def read_rules(cfg: Config) -> str:
    parts = []
    for name in RULE_FILES:
        path = cfg.assistant_path / "rules" / name
        if path.exists():
            parts.append(f"### rules/{name}\n{path.read_text(encoding='utf-8').strip()}")
    return "\n\n".join(parts)


def folder_tree(cfg: Config) -> str:
    """Folder outline with note counts, so the model can pick placements cheaply."""
    root = cfg.vault_path
    patterns = ignore_list(cfg) + [cfg.assistant_dir]
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel = PurePosixPath(Path(dirpath).relative_to(root).as_posix())
        depth = 0 if str(rel) == "." else len(rel.parts)
        dirnames[:] = sorted(
            d
            for d in dirnames
            if not d.startswith(".") and not _is_ignored(rel / d if depth else PurePosixPath(d), patterns)
        )
        if depth >= cfg.tree_depth:
            dirnames[:] = []
        notes = sum(1 for f in filenames if f.endswith(".md"))
        if depth:
            lines.append(f"{'  ' * (depth - 1)}{rel.name}/ ({notes})")
    return "\n".join(lines)
