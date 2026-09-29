"""Configuration and on-disk locations.

Everything the engine needs outside the vault (config, state, status, locks)
lives under a single support directory so the vault only receives user-facing notes.
"""

import json
import os
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import List

from .i18n import normalize, tr

SUPPORT_DIR = Path(
    os.environ.get(
        "PA_HOME",
        str(Path.home() / "Library" / "Application Support" / "Sift"),
    )
)


class ConfigError(ValueError):
    pass


@dataclass
class Config:
    vault: str = ""  # chosen in the menu bar settings on first run
    inbox: str = "00-inbox/active.md"  # relative to vault
    assistant_dir: str = "99-assistant"  # relative to vault
    check_interval_minutes: float = 2  # launchd wakes every minute; checks happen this often
    quiet_minutes: float = 5  # rule A: file untouched this long before processing
    last_block_hold_minutes: float = 10  # rule B: last block must be stable this long
    dry_run: bool = True
    paused: bool = False
    engine: str = "codex"
    codex_path: str = "/opt/homebrew/bin/codex"
    open_with: str = ""  # app used by the menu bar to open notes; empty = macOS default app
    language: str = "en"  # "en" or "ko": status, vault headings, default rules (earlier configs without it read as "ko")
    codex_model: str = ""  # empty = codex default
    codex_timeout_seconds: int = 600
    history_size: int = 20
    review_threshold: float = 0.7  # items below this confidence are flagged for review
    candidates_per_block: int = 8
    tree_depth: int = 3
    exclude: List[str] = field(
        default_factory=lambda: [".obsidian", ".trash", ".git", "excalidraw", "assets"]
    )

    def __post_init__(self) -> None:
        self.language = normalize(self.language)

    @property
    def vault_path(self) -> Path:
        return Path(self.vault).expanduser()

    @property
    def inbox_path(self) -> Path:
        return self.vault_path / self.inbox

    @property
    def assistant_path(self) -> Path:
        return self.vault_path / self.assistant_dir

    def check_locations(self) -> None:
        """The inbox must be a markdown file inside the vault, outside the assistant folder."""
        if not self.vault.strip():
            raise ConfigError(tr("No vault is set. Choose a vault folder in the menu bar settings.",
                                 "vault가 설정되지 않았습니다. 메뉴바의 설정에서 vault 폴더를 고르세요."))
        root = self.vault_path
        if not root.is_absolute() or not root.is_dir():
            raise ConfigError(tr(f"The vault folder doesn't exist: {root}", f"vault 폴더가 없습니다: {root}"))
        try:
            os.listdir(root)
        except PermissionError:
            raise ConfigError(tr(
                f"No permission to access the vault folder: {root}. "
                "Allow Sift in System Settings > Privacy & Security > Files and Folders.",
                f"vault 폴더에 접근할 권한이 없습니다: {root}. "
                "시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더에서 Sift를 허용하세요.",
            )) from None
        rel = Path(self.inbox)
        if rel.is_absolute() or ".." in rel.parts or rel.suffix != ".md":
            raise ConfigError(tr(f"The inbox must be a relative path to a .md file inside the vault: {self.inbox}",
                                 f"inbox는 vault 안의 .md 파일 상대 경로여야 합니다: {self.inbox}"))
        if rel.parts[0] == Path(self.assistant_dir).parts[0]:
            raise ConfigError(tr(f"The inbox can't be inside {self.assistant_dir}/: {self.inbox}",
                                 f"inbox를 {self.assistant_dir}/ 안에 둘 수 없습니다: {self.inbox}"))
        if not self.inbox_path.resolve().is_relative_to(root.resolve()):
            raise ConfigError(tr(f"The inbox points outside the vault: {self.inbox}", f"inbox가 vault 밖을 가리킵니다: {self.inbox}"))
        if not self.inbox_path.is_file():  # never created behind the user's back
            raise ConfigError(tr(f"The inbox file doesn't exist: {self.inbox}. Choose the inbox in settings.",
                                 f"inbox 파일이 없습니다: {self.inbox}. 설정에서 inbox를 고르세요."))


def support_dir() -> Path:
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    return SUPPORT_DIR


def config_path() -> Path:
    return support_dir() / "config.json"


def load_config() -> Config:
    path = config_path()
    if not path.exists():
        cfg = Config()
        save_config(cfg)
        return cfg
    raw = json.loads(path.read_text(encoding="utf-8"))
    # Configs written since the language choice always carry it (new ones get it from
    # Config() above or from the app); one without it comes from the Korean-only versions.
    raw.setdefault("language", "ko")
    known = {f.name for f in fields(Config)}
    return Config(**{k: v for k, v in raw.items() if k in known})


def save_config(cfg: Config) -> None:
    path = config_path()
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(asdict(cfg), ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)
