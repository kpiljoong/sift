"""One Mac sorts a vault at a time.

Vaults are often synced between Macs (iCloud, Obsidian Sync, LiveSync). If two Macs
both sort the same inbox, notes get filed twice and appends conflict. The Mac that
sorts leaves a marker in the assistant folder; another Mac that sees a recent marker
from someone else stops and says so, until the user picks which Mac sorts.

The marker isn't a dotfile: sync tools such as Obsidian LiveSync skip hidden files.
"""

import json
import socket
import subprocess
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional

from .config import Config, support_dir
from .state import iso, now

MARKER = "sift-processor.json"
FRESH_HOURS = 24  # a marker this recent means that Mac is still sorting the vault
REFRESH_MINUTES = 30  # how often the sorting Mac renews its marker


def machine_id() -> str:
    path = support_dir() / "machine-id"
    if not path.exists():
        path.write_text(uuid.uuid4().hex, encoding="utf-8")
    return path.read_text(encoding="utf-8").strip()


def machine_name() -> str:
    try:
        name = subprocess.run(["/usr/sbin/scutil", "--get", "ComputerName"], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        name = ""
    return name or socket.gethostname()


def marker_path(cfg: Config) -> Path:
    return cfg.assistant_path / MARKER


def read(cfg: Config) -> Optional[Dict[str, Any]]:
    try:
        data = json.loads(marker_path(cfg).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("id") else None


def age_hours(marker: Dict[str, Any], at: Optional[datetime] = None) -> float:
    try:
        then = datetime.fromisoformat(str(marker.get("at")))
    except ValueError:
        return float("inf")
    return ((at or now()) - then).total_seconds() / 3600


def other(cfg: Config, at: Optional[datetime] = None) -> Optional[Dict[str, Any]]:
    """The marker of another Mac that sorted this vault recently, if any."""
    marker = read(cfg)
    if marker and marker["id"] != machine_id() and age_hours(marker, at) < FRESH_HOURS:
        return marker
    return None


def claim(cfg: Config, force: bool = False, at: Optional[datetime] = None) -> None:
    """Mark this Mac as the one sorting the vault (renewed every REFRESH_MINUTES)."""
    marker = read(cfg)
    mine = bool(marker) and marker["id"] == machine_id()
    if not force and mine and age_hours(marker, at) * 60 < REFRESH_MINUTES:
        return
    cfg.assistant_path.mkdir(parents=True, exist_ok=True)
    data = {"id": machine_id(), "name": machine_name(), "at": iso(at or now())}
    marker_path(cfg).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def claim_request() -> Path:
    """Dropped by the menu bar's "Sort on this Mac" button."""
    return support_dir() / "claim-vault"
