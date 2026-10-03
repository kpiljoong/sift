"""Persistent engine state (state.json) and the status snapshot read by the menu bar app."""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

from .config import support_dir

EMPTY_STATE: Dict[str, Any] = {
    "vault": "",  # vault these block hashes and history paths belong to
    "seen": {},  # block text hash -> ISO time first seen (rule B stability)
    "pending_removal": [],  # block texts already applied but not yet removed from inbox
    "dry_run_seen": [],  # block hashes already proposed in dry-run mode
    "history": [],  # recent processed items, newest last
    "ready": [],  # block hashes from quick notes: finished writing, skip rules A/B
    "groups": [],  # lists of block hashes written as one note (e.g. a note with a Request: line)
    "stats": {},  # YYYY-MM-DD -> counters
    "review": [],  # history entries still waiting for the user's check, newest last
    "resorts": {},  # first block hash of a re-sort -> the history entry it replaces
}


def now() -> datetime:
    return datetime.now().astimezone()


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def _read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write_json(path: Path, data: Any) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def state_path() -> Path:
    return support_dir() / "state.json"


def status_path() -> Path:
    return support_dir() / "status.json"


def run_now_flag() -> Path:
    return support_dir() / "run-now"


def load_state() -> Dict[str, Any]:
    state = _read_json(state_path(), {})
    for key, value in EMPTY_STATE.items():
        state.setdefault(key, json.loads(json.dumps(value)))
    return state


def reset_for_vault(state: Dict[str, Any], vault: str) -> bool:
    """History and block bookkeeping are per vault; drop them when the vault changes."""
    previous = state.get("vault") or ""
    state["vault"] = vault
    if not previous or previous == vault:
        return False
    for key in ("seen", "pending_removal", "dry_run_seen", "history", "review", "resorts"):
        state[key] = json.loads(json.dumps(EMPTY_STATE[key]))
    return True


def save_state(state: Dict[str, Any]) -> None:
    _write_json(state_path(), state)


def bump(state: Dict[str, Any], key: str, amount: int = 1) -> None:
    day = now().strftime("%Y-%m-%d")
    stats = state["stats"]
    stats.setdefault(day, {})
    stats[day][key] = stats[day].get(key, 0) + amount
    for old in sorted(stats)[:-14]:  # keep two weeks
        del stats[old]


def write_status(**fields: Any) -> None:
    """Merge fields into status.json; the menu bar app polls this file."""
    status = _read_json(status_path(), {})
    status.update(fields)
    status["updated_at"] = iso(now())
    _write_json(status_path(), status)


def read_status() -> Dict[str, Any]:
    return _read_json(status_path(), {})
