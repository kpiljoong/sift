"""AI engines. An engine turns a prompt into a plan dict matching PLAN_SCHEMA.

The model gets no file access at all: codex runs in an empty temp directory with
its shell tool disabled, so everything it knows about the vault comes from the
prompt (built from the local index, which honours .assistantignore). Applying the
plan is done by engine.py under code-enforced rules.
"""

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict

from .config import Config

ACTION_TYPES = ["create", "append", "todo", "calendar", "review"]
KINDS = ["todo", "project", "idea", "meeting", "note", "calendar", "other"]

PLAN_SCHEMA: Dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["items"],
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["block_ids", "kind", "title", "continues", "confidence", "properties", "actions"],
                "properties": {
                    "block_ids": {"type": "array", "items": {"type": "string"}},
                    "kind": {"type": "string", "enum": KINDS},
                    "title": {"type": "string"},
                    "continues": {"type": ["string", "null"]},
                    "confidence": {"type": "number"},
                    "properties": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["type", "project", "tags"],
                        "properties": {
                            "type": {"type": "array", "items": {"type": "string"}},
                            "project": {"type": ["string", "null"]},
                            "tags": {"type": "array", "items": {"type": "string"}},
                        },
                    },
                    "actions": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["type", "path", "content", "reason"],
                            "properties": {
                                "type": {"type": "string", "enum": ACTION_TYPES},
                                "path": {"type": ["string", "null"]},
                                "content": {"type": "string"},
                                "reason": {"type": "string"},
                            },
                        },
                    },
                },
            },
        }
    },
}


# No shell (so no file reads) and no app/browser integrations for the planning call.
LOCKED_FEATURES = ["shell_tool", "apps", "plugins", "browser_use", "computer_use", "in_app_browser"]


class EngineError(Exception):
    pass


class CodexEngine:
    name = "codex"

    def __init__(self, cfg: Config):
        self.cfg = cfg

    def plan(self, prompt: str) -> Dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="pa-codex-") as tmp:
            schema = Path(tmp) / "schema.json"
            out = Path(tmp) / "out.json"
            schema.write_text(json.dumps(PLAN_SCHEMA), encoding="utf-8")
            cmd = [
                self.cfg.codex_path,
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--sandbox", "read-only",
                "--cd", tmp,
                "--output-schema", str(schema),
                "--output-last-message", str(out),
                "--color", "never",
            ]
            for feature in LOCKED_FEATURES:
                cmd += ["--disable", feature]
            if self.cfg.codex_model:
                cmd += ["--model", self.cfg.codex_model]
            cmd.append("-")
            try:
                proc = subprocess.run(
                    cmd,
                    input=prompt,
                    capture_output=True,
                    text=True,
                    timeout=self.cfg.codex_timeout_seconds,
                )
            except subprocess.TimeoutExpired:
                raise EngineError(f"codex timed out after {self.cfg.codex_timeout_seconds}s")
            except FileNotFoundError:
                raise EngineError(f"codex not found at {self.cfg.codex_path}")
            if proc.returncode != 0 or not out.exists():
                tail = (proc.stderr or proc.stdout or "").strip()[-800:]
                raise EngineError(f"codex exited {proc.returncode}: {tail}")
            try:
                return json.loads(out.read_text(encoding="utf-8"))
            except ValueError as exc:
                raise EngineError(f"codex returned invalid JSON: {exc}")


def make_engine(cfg: Config):
    if cfg.engine == "codex":
        return CodexEngine(cfg)
    raise EngineError(f"unsupported engine: {cfg.engine}")
