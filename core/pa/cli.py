"""Command line: `python3 -m pa run|status|init|set KEY VALUE`."""

import argparse
import json
import sys
from dataclasses import asdict, fields

from .config import Config, ConfigError, load_config, save_config
from .engine import check_due, mark_checked, run_once
from .i18n import normalize, set_language, tr
from .state import read_status
from .vault import init_assistant_dir


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="pa", description="Sift core")
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="process the inbox once")
    run.add_argument("--force", action="store_true", help="process everything now, including the last block")
    run.add_argument("--scheduled", action="store_true", help="launchd tick: skip until check_interval_minutes passed")
    sub.add_parser("status", help="print status.json")
    sub.add_parser("config", help="print config")
    sub.add_parser("init", help="create the assistant folder in the vault")
    setp = sub.add_parser("set", help="change a config value")
    setp.add_argument("key")
    setp.add_argument("value", help="JSON value, e.g. false, 10, \"text\"")
    args = parser.parse_args(argv)
    set_language(load_config().language)

    if args.cmd == "run":
        if args.scheduled:
            if not check_due(load_config()):
                return 0
            mark_checked()
        before = read_status().get("last_error")
        try:
            result = run_once(force=args.force)
        except ConfigError as exc:
            # status.json shows it in the menu bar; log only when the problem changes
            if load_config().vault.strip() and str(exc) != before:
                print(f"error: {exc}", file=sys.stderr)
            return 1
        except Exception as exc:  # already recorded in status.json
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(result, ensure_ascii=False))
    elif args.cmd == "status":
        print(json.dumps(read_status(), ensure_ascii=False, indent=2))
    elif args.cmd == "config":
        print(json.dumps(asdict(load_config()), ensure_ascii=False, indent=2))
    elif args.cmd == "init":
        cfg = load_config()
        if not cfg.vault.strip():
            print(tr("Skipped: no vault is set yet (it's created on the first check after you choose a vault and inbox in the menu bar)",
                     "vault가 아직 설정되지 않아 건너뜀 (메뉴바에서 vault와 inbox를 고르면 첫 확인 때 만듭니다)"))
            return 0
        init_assistant_dir(cfg)
        print(f"initialized {cfg.assistant_path}")
    elif args.cmd == "set":
        cfg = load_config()
        if args.key not in {f.name for f in fields(Config)}:
            print(f"unknown key: {args.key}", file=sys.stderr)
            return 2
        try:
            value = json.loads(args.value)
        except ValueError:
            value = args.value
        if args.key == "language":
            value = normalize(str(value))
        setattr(cfg, args.key, value)
        save_config(cfg)
        print(f"{args.key} = {json.dumps(value, ensure_ascii=False)}")
    return 0
