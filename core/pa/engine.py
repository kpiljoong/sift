"""One processing pass over the inbox.

Flow: read inbox -> retry pending removals -> pick eligible blocks (rules A/B)
-> ask the AI for a plan -> verify the inbox did not change meanwhile -> apply
the plan (append/create only) -> archive blocks -> remove them from the inbox.
"""

import fcntl
import json
import re
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from . import processor, vault
from .config import Config, ConfigError, config_path, load_config, support_dir
from .i18n import set_language, tr
from .inbox import Block, content_hash, remove_blocks, split_blocks
from .index import Searcher, update_index
from .llm import EngineError, make_engine
from .prompt import build_prompt
from .state import bump, iso, load_state, now, reset_for_vault, run_now_flag, save_state, write_status


class Run:
    def __init__(self, cfg: Config, engine=None, force: bool = False):
        self.cfg = cfg
        set_language(cfg.language)
        self.engine = engine or make_engine(cfg)
        self.force = force
        self.state = load_state()
        self.vault_changed = reset_for_vault(self.state, str(cfg.vault_path))
        self.t = now()
        self.stamp = self.t.strftime("%Y-%m-%d %H:%M")
        self.root = cfg.assistant_path
        self.archive_rel = f"{cfg.assistant_dir}/inbox-archive/{self.t.strftime('%Y-%m')}"

    # ---------- helpers ----------

    def rel(self, path: Path) -> str:
        return path.relative_to(self.cfg.vault_path).as_posix()

    def log(self, line: str) -> None:
        vault.append_line(self.root / "log" / f"{self.t.strftime('%Y-%m-%d')}.md", f"- {self.t.strftime('%H:%M')} {line}")

    def anchor(self, block_id: str) -> str:
        return f"{self.stamp.replace(':', '')} {block_id}"

    def source_link(self, block_id: str) -> str:
        return f"[[{self.archive_rel}#{self.anchor(block_id)}|{tr('source', '원문')}]]"

    def read_inbox(self) -> Tuple[str, float]:
        path = self.cfg.inbox_path
        return path.read_text(encoding="utf-8"), path.stat().st_mtime

    def quiet(self, mtime: float) -> bool:
        idle = self.t.timestamp() - mtime
        return self.force or idle >= self.cfg.quiet_minutes * 60

    def write_inbox(self, expected_hash: str, new_content: str) -> bool:
        """Replace the inbox only if it still has the content we planned against."""
        current, _ = self.read_inbox()
        if content_hash(current) != expected_hash:
            return False
        backup = self.root / "backup" / f"active-{self.t.strftime('%Y%m%d-%H%M%S')}.md"
        if not backup.exists():
            vault.create(backup, current)
        self.cfg.inbox_path.write_text(new_content, encoding="utf-8")
        return True

    # ---------- steps ----------

    def retry_pending(self, content: str, mtime: float) -> str:
        pending = self.state["pending_removal"]
        if not pending or not self.quiet(mtime):
            return content
        new, removed = remove_blocks(content, pending)
        if removed:
            if not self.write_inbox(content_hash(content), new):
                return content  # changed underneath us; keep pending for next run
            self.log(tr(f"Cleared {len(removed)} processed block(s) from the inbox (retry)",
                        f"inbox에서 처리된 블록 {len(removed)}개 정리 (재시도)"))
            content = new
        missing = len(pending) - len(removed)
        if missing:
            self.log(tr(f"Dropped {missing} processed block(s) that are no longer in the inbox from cleanup (they seem edited)",
                        f"처리됐지만 inbox에서 찾을 수 없는 블록 {missing}개는 정리 대상에서 뺌 (수정된 것으로 보임)"))
        self.state["pending_removal"] = []
        return content

    def eligible(self, blocks: List[Block], mtime: float) -> Tuple[List[Block], Optional[str]]:
        seen: Dict[str, str] = self.state["seen"]
        current = {}
        for b in blocks:
            h = content_hash(b.text)
            current[h] = seen.get(h, iso(self.t))
        self.state["seen"] = current
        self.state["ready"] = [h for h in self.state["ready"] if h in current]
        self.state["groups"] = [g for g in ([h for h in g if h in current] for g in self.state["groups"]) if len(g) > 1]
        ready = set(self.state["ready"])

        def is_ready(b: Block) -> bool:
            return content_hash(b.text) in ready

        pending = set(self.state["pending_removal"])
        skip = set(self.state["dry_run_seen"]) if self.cfg.dry_run else set()
        todo = [b for b in blocks if b.text not in pending and content_hash(b.text) not in skip]
        if not todo:
            return [], None
        if not self.quiet(mtime):
            ready_at = datetime.fromtimestamp(mtime).astimezone() + timedelta(minutes=self.cfg.quiet_minutes)
            # quick notes are finished text; only the rest waits for the editor to go quiet
            at = ready_at.strftime('%H:%M')
            return [b for b in todo if is_ready(b)], tr(f"Waiting while you write (processing after {at})",
                                                        f"작성 중으로 보여 대기 ({at} 이후 처리)")
        last = blocks[-1]
        held = None
        if todo[-1] is last and not self.force and not is_ready(last):  # run-now means "done writing"
            since = datetime.fromisoformat(current[content_hash(last.text)])
            ready_at = since + timedelta(minutes=self.cfg.last_block_hold_minutes)
            if self.t < ready_at:
                todo = todo[:-1]
                at = ready_at.strftime('%H:%M')
                held = tr(f"Holding the last block in case you keep writing (processing after {at})",
                          f"마지막 블록은 이어 쓸 수 있어 보류 ({at} 이후 처리)")
        return todo, held

    def apply(self, plan: Dict[str, Any], blocks: List[Block]) -> List[str]:
        """Apply (or, in dry-run, describe) the plan. Returns human-readable lines."""
        by_id = {b.id: b for b in blocks}
        used = set()
        lines: List[str] = []
        history = self.state["history"]

        for item in plan.get("items", []):
            ids = [i for i in item.get("block_ids", []) if i in by_id and i not in used]
            if not ids:
                continue
            used.update(ids)
            item["confidence"] = _clamp(item.get("confidence"))
            link = self.source_link(ids[0])
            targets: List[str] = []
            flag = tr(" ⚠️ needs review", " ⚠️ 확인 필요") if self.low(item) else ""
            lines.append(
                f"- **{item.get('title', '')}** ({item.get('kind')}, confidence {item['confidence']:.2f}{flag}, "
                + tr("block", "블록") + f" {', '.join(ids)})"
            )
            actions = item.get("actions") or [
                {"type": "review", "path": None,
                 "reason": tr("the AI found nothing to record", "AI가 기록할 것이 없다고 판단"),
                 "content": tr("The AI decided not to record anything for this note (it may already be recorded).",
                               "AI가 이 메모에 대해 아무것도 기록하지 않기로 했습니다 (이미 기록된 내용일 수 있음).")
                            + "\n\n" + "\n\n".join(by_id[i].text for i in ids)}
            ]
            for action in actions:
                desc = self.apply_action(action, item, link, targets)
                lines.append(f"  - {desc}")
            if not self.cfg.dry_run:  # history drives continuation; only real writes count
                history.append(
                    {
                        "id": ids[0],
                        "ids": ids,  # re-sort finds every block of the item in the archive
                        "time": self.stamp,
                        "kind": item.get("kind", "other"),
                        "title": item.get("title", ""),
                        "confidence": item["confidence"],
                        "targets": targets,
                    }
                )

        leftover = [b for b in blocks if b.id not in used]
        if leftover:
            text = "\n\n".join(b.text for b in leftover)
            desc = self.apply_action(
                {"type": "review", "path": None,
                 "content": tr("Blocks the AI didn't sort:", "AI가 분류하지 않은 블록:") + f"\n\n{text}",
                 "reason": tr("missing from the plan", "계획에서 누락")},
                {"kind": "other", "confidence": 0.0},
                self.source_link(leftover[0].id),
                [],
            )
            lines.append(f"- **{tr('Unsorted blocks', '분류되지 않은 블록')}** ({', '.join(b.id for b in leftover)})\n  - {desc}")

        self.state["history"] = history[-self.cfg.history_size :]
        return lines

    def low(self, item: Dict[str, Any]) -> bool:
        return item.get("confidence", 0.0) < self.cfg.review_threshold

    def frontmatter(self, item: Dict[str, Any], review: bool = False) -> str:
        props = item.get("properties") or {}
        types = [t for t in (props.get("type") or []) if t] or [item.get("kind", "note")]
        tags = [_tag(t) for t in (props.get("tags") or []) if _tag(t)]
        if review and REVIEW_TAG not in tags:
            tags.append(REVIEW_TAG)
        out = ["---", "type:"] + [f"  - {_yaml(t)}" for t in types]
        if props.get("project"):
            out.append(f"project: {_yaml(props['project'])}")
        out.append(f"date: {self.t.strftime('%Y-%m-%d')}")
        if tags:
            out += ["tags:"] + [f"  - {t}" for t in tags]
        if item.get("kind") == "meeting":
            out.append('categories: "[[Meetings]]"')
        out += ["source: assistant", f"confidence: {item['confidence']:.2f}", "---"]
        return "\n".join(out)

    def apply_action(self, action: Dict[str, Any], item: Dict[str, Any], link: str, targets: List[str]) -> str:
        kind = action.get("type")
        content = (action.get("content") or "").strip()
        path_rel = action.get("path")
        dry = self.cfg.dry_run
        # Appended lines can't carry frontmatter, so low confidence is marked with a tag.
        mark = f" #{REVIEW_TAG}" if self.low(item) else ""
        footer = f"— assistant · {self.stamp} · confidence {item.get('confidence', 0):.2f} · {link}{mark}"

        def to_review(reason: str) -> str:
            return self.apply_action(
                {"type": "review", "path": None, "content": f"{content}\n\n(" + tr("original plan", "원래 계획") + f": {kind} → {path_rel}; {reason})", "reason": reason},
                item,
                link,
                targets,
            )

        try:
            if kind == "todo":
                tasks = [l.strip() for l in content.splitlines() if l.strip().startswith("- [ ]")]
                if not tasks:
                    return to_review(tr("not in todo format", "todo 형식이 아님"))
                target = vault.resolve_note(self.cfg, path_rel) if path_rel else self.root / "todo.md"
                text = "\n".join(f"{t} {link}{mark}" for t in tasks)
                if not dry:
                    vault.append(target, text)
                    bump(self.state, "todos", len(tasks))
                targets.append(self.rel(target))
                return tr(f"{len(tasks)} todo(s)", f"todo {len(tasks)}개") + f" → `{self.rel(target)}`\n" + "\n".join(f"    {t}" for t in tasks)

            if kind in ("create", "append"):
                content = _strip_frontmatter(content)
                if not content:
                    return tr("(skipped: empty content)", "(빈 내용이라 건너뜀)")
                path_rel = vault.reuse_similar_folder(self.cfg, path_rel or "")  # agent-note/ → existing agent-notes/
                target = vault.resolve_note(self.cfg, path_rel)
                if kind == "append" and not target.exists():
                    kind = "create"
                if kind == "create" and target.exists():
                    kind = "append"  # never overwrite
                new_folder = vault.new_project_folder(self.cfg, target)
                if new_folder:  # a new project folder: allowed, but always shown for review
                    footer += "" if mark else f" #{REVIEW_TAG}"
                if kind == "create":
                    body = f"{self.frontmatter(item, review=bool(new_folder))}\n\n{content}\n\n{footer}"
                else:
                    body = f"{content}\n\n{footer}"
                if not dry:
                    if kind == "create":
                        vault.create(target, body)
                    else:
                        vault.append(target, body)
                    bump(self.state, "docs")
                targets.append(self.rel(target))
                verb = tr("new note", "새 문서") if kind == "create" else tr("appended to existing note", "기존 문서에 추가")
                if new_folder:
                    verb += tr(f" in new folder `{new_folder}/`", f" (새 폴더 `{new_folder}/`)")
                return f"{verb} → `{self.rel(target)}` ({action.get('reason', '')})\n" + _indent(content)

            if kind == "calendar":
                target = self.root / "calendar-queue.md"
                line = content.splitlines()[0] if content else ""
                if not line.startswith("- [ ]"):
                    line = f"- [ ] {line}"
                if not dry:
                    vault.append(target, f"{line} {link}{mark}")
                    bump(self.state, "calendar")
                targets.append(self.rel(target))
                return tr("calendar candidate", "일정 후보") + f" → `{self.rel(target)}`\n    {line}"

            if kind == "review":
                target = self.root / "review" / f"{self.t.strftime('%Y-%m-%d')}.md"
                if not dry:
                    vault.append(target, f"## {self.stamp} {tr('Needs review', '확인 필요')}\n{content}\n\n{footer}")
                    bump(self.state, "review")
                targets.append(self.rel(target))
                return f"review → `{self.rel(target)}` ({action.get('reason', '')})\n" + _indent(content)

            return tr(f"(ignored unknown action `{kind}`)", f"(알 수 없는 action `{kind}` 무시)")
        except vault.UnsafePath as exc:
            return to_review(tr("safety rule violation", "안전 규칙 위반") + f": {exc}")

    def archive(self, blocks: List[Block]) -> None:
        target = self.cfg.vault_path / f"{self.archive_rel}.md"
        for b in blocks:
            vault.append(target, f"## {self.anchor(b.id)}\n{b.text}")

    # ---------- main ----------

    def execute(self) -> Dict[str, Any]:
        cfg = self.cfg
        vault.init_assistant_dir(cfg)
        if self.vault_changed:
            self.log(tr(f"The vault changed to {cfg.vault_path}; starting the history over",
                        f"vault가 {cfg.vault_path}로 바뀌어 처리 이력을 새로 시작"))
        content, mtime = self.read_inbox()
        content = self.retry_pending(content, mtime)
        blocks = split_blocks(content)
        todo, held = self.eligible(blocks, mtime)
        result: Dict[str, Any] = {"blocks": len(blocks), "processed": 0, "held": held}

        if not todo:
            update_index(cfg)  # keeps the quick note's @ list fresh between runs
            save_state(self.state)
            result["message"] = held or (tr("Nothing to process", "처리할 내용 없음") if not blocks
                                         else tr("All processed", "모두 처리됨"))
            return result

        write_status(state="processing", detail=tr(f"Analyzing {len(todo)} block(s)", f"블록 {len(todo)}개 분석 중"))
        snapshot = content_hash(content)
        searcher = Searcher(update_index(cfg))
        by_hash = {content_hash(b.text): b.id for b in todo}
        groups = [[by_hash[h] for h in g if h in by_hash] for g in self.state["groups"]]
        prompt = build_prompt(cfg, todo, self.state["history"], searcher, [g for g in groups if len(g) > 1])
        plan = self.engine.plan(prompt)

        now_content, _ = self.read_inbox()
        if content_hash(now_content) != snapshot:
            save_state(self.state)
            self.log(tr("The inbox changed during analysis; discarded this result, will process again next round",
                        "분석 중 inbox가 수정되어 이번 결과는 버리고 다음 회차에 다시 처리"))
            result["message"] = tr("The inbox changed during analysis; retrying next round",
                                   "분석 중 inbox가 수정되어 다음 회차에 재시도")
            return result

        lines = self.apply(plan, todo)
        bump(self.state, "blocks", len(todo))
        result["processed"] = len(todo)

        if cfg.dry_run:
            report = self.root / "review" / f"dry-run-{self.t.strftime('%Y-%m-%d')}.md"
            vault.append(
                report,
                f"## {self.stamp} dry-run ({tr('nothing was written', '실제로 기록하지 않음')})\n"
                + "\n".join(f"> {b.text}".replace("\n", "\n> ") for b in todo)
                + "\n\n"
                + "\n".join(lines),
            )
            self.state["dry_run_seen"] = (self.state["dry_run_seen"] + [content_hash(b.text) for b in todo])[-500:]
            self.log(tr(f"[dry-run] proposals for {len(todo)} block(s)", f"[dry-run] 블록 {len(todo)}개 제안")
                     + f" → [[{self.rel(report)}]]")
            result["message"] = tr(f"dry-run: wrote proposals for {len(todo)} block(s)", f"dry-run: 블록 {len(todo)}개 제안 작성")
        else:
            self.archive(todo)
            self.state["pending_removal"] = [b.text for b in todo]
            save_state(self.state)  # persist before touching the inbox
            new, _ = remove_blocks(content, self.state["pending_removal"])
            if self.write_inbox(snapshot, new):
                self.state["pending_removal"] = []
            for l in lines:
                self.log(l.splitlines()[0].strip().lstrip("- "))
            result["message"] = tr(f"Processed {len(todo)} block(s)", f"블록 {len(todo)}개 처리")

        save_state(self.state)
        return result


REVIEW_TAG = "assistant/review"


def _clamp(value: Any) -> float:
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def _yaml(value: str) -> str:
    value = str(value).strip()
    if re.fullmatch(r"[\w가-힣][\w가-힣 ./-]*", value):
        return value
    return json.dumps(value, ensure_ascii=False)


def _tag(value: str) -> str:
    return re.sub(r"[^\w가-힣/-]", "", str(value).strip().lstrip("#").replace(" ", "-"))


def _strip_frontmatter(text: str) -> str:
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            return text[end + 4 :].strip()
    return text


def _indent(text: str, limit: int = 12) -> str:
    rows = text.splitlines()
    shown = rows[:limit] + (["…"] if len(rows) > limit else [])
    return "\n".join(f"    > {r}" for r in shown)


def quick_dir() -> Path:
    return support_dir() / "quick"


def archived_text(cfg: Config, entry: Dict[str, Any]) -> Optional[str]:
    """The original inbox text of a history entry, read back from the inbox archive."""
    stamp = str(entry.get("time", ""))
    ids = [str(i) for i in entry.get("ids") or [entry.get("id")] if i]
    archive = cfg.assistant_path / "inbox-archive" / f"{stamp[:7]}.md"
    if not ids or len(stamp) < 16 or not archive.exists():
        return None
    sections = re.split(r"^## ", archive.read_text(encoding="utf-8"), flags=re.M)
    anchors = {f"{stamp.replace(':', '')} {i}" for i in ids}
    found = []
    for sec in sections:
        head, _, body = sec.partition("\n")
        if head.strip() in anchors:
            found.append(body.strip("\n"))
    return "\n\n".join(found) or None


def resort_note(cfg: Config, entry: Dict[str, Any], instruction: str) -> Tuple[str, str]:
    """Turns a re-sort request into inbox text + request line, and records the correction
    in rules/corrections.md so later runs learn from it. The earlier entry is left in place
    (the assistant never deletes); the menu bar tells the user."""
    set_language(cfg.language)
    title = str(entry.get("title", "")).strip()
    targets = ", ".join(entry.get("targets") or []) or tr("nothing recorded", "기록 없음")
    text = archived_text(cfg, entry) or title
    request = tr(f"Re-sort — this was filed in {targets} before, but the user corrected it: {instruction}. "
                 "Don't write to the earlier location again; file it as instructed.",
                 f"다시 정리 — 이전에 {targets}에 정리했지만 사용자가 바로잡음: {instruction}. "
                 "이전 위치에는 다시 쓰지 말고 지시대로 정리하세요.")
    vault.init_assistant_dir(cfg)
    day, kind = now().strftime('%Y-%m-%d'), entry.get('kind', '')
    vault.append_line(cfg.assistant_path / "rules" / "corrections.md",
                      tr(f"- {day} \"{title}\" {kind} → {targets} was corrected: {instruction}",
                         f"- {day} 「{title}」 {kind} → {targets} 였던 것을 바로잡음: {instruction}"))
    return text, request


def ingest_quick_notes(cfg: Config) -> int:
    """Append notes saved by the menu bar quick-note panel to the inbox.

    Runs under the run lock so it never races the engine's own inbox rewrite.
    Their blocks are marked ready: the user already finished writing them.
    """
    set_language(cfg.language)
    files = sorted(f for f in quick_dir().glob("*") if f.suffix in (".md", ".json")) if quick_dir().exists() else []
    if not files:
        return 0
    parts, grouped = [], []
    for f in files:
        raw = f.read_text(encoding="utf-8")
        note = json.loads(raw) if f.suffix == ".json" else {"text": raw}
        text = (note.get("text") or "").strip("\n")
        request = (note.get("request") or "").strip()
        if isinstance(note.get("resort"), dict) and request:
            text, request = resort_note(cfg, note["resort"], request)
            note["group"] = True
        if request:
            prefix = tr("Request:", "요청:")
            text = f"{prefix} {request}\n{text}" if text.strip() else f"{prefix} {request}"
        if text.strip():
            parts.append(text)
            if request or note.get("group"):
                grouped.append(text)
    if parts:
        vault.init_assistant_dir(cfg)
        current = cfg.inbox_path.read_text(encoding="utf-8")
        if not current.strip() or current.endswith("\n\n"):
            sep = ""
        else:
            sep = "\n" if current.endswith("\n") else "\n\n"
        with cfg.inbox_path.open("a", encoding="utf-8") as fh:
            fh.write(sep + "\n\n".join(parts) + "\n")
        state = load_state()
        state["ready"] += [content_hash(b.text) for p in parts for b in split_blocks(p)]
        for text in grouped:
            hashes = [content_hash(b.text) for b in split_blocks(text)]
            if len(hashes) > 1:
                state["groups"].append(hashes)
        save_state(state)
    for f in files:
        f.unlink()
    return len(parts)


def remaining_blocks(cfg: Config, fallback: int) -> int:
    """Blocks left in the inbox after a run (the count before the run would show processed ones)."""
    try:
        return len(split_blocks(cfg.inbox_path.read_text(encoding="utf-8")))
    except OSError:
        return fallback


def check_due(cfg: Config, at: Optional[float] = None) -> bool:
    """Scheduled wakeups skip until the check interval has passed.

    "Run now" requests and config changes (settings, locations) always check right away.
    """
    at = time.time() if at is None else at
    marker = support_dir() / "last-check"
    if run_now_flag().exists() or processor.claim_request().exists() or not marker.exists() or any(quick_dir().glob("*.*")):
        return True
    last = marker.stat().st_mtime
    if config_path().exists() and config_path().stat().st_mtime > last:
        return True
    return at - last >= cfg.check_interval_minutes * 60 - 15  # launchd ticks are not exact


def mark_checked() -> None:
    (support_dir() / "last-check").touch()


def run_once(force: bool = False, engine=None, cfg: Optional[Config] = None) -> Dict[str, Any]:
    cfg = cfg or load_config()
    set_language(cfg.language)
    flag = run_now_flag()
    if flag.exists():
        force = True
        flag.unlink()

    lock = open(support_dir() / "run.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return {"message": tr("Already running", "이미 실행 중")}

    base = {"dry_run": cfg.dry_run, "paused": cfg.paused, "vault": str(cfg.vault_path),
            "inbox": str(cfg.inbox_path), "assistant_dir": str(cfg.assistant_path)}
    try:
        try:
            cfg.check_locations()
        except ConfigError as exc:
            write_status(state="error", detail=tr("Location settings error", "위치 설정 오류"), last_error=str(exc), last_run_at=iso(now()), **base)
            raise
        quick = ingest_quick_notes(cfg)  # user input: added even while paused
        if cfg.paused and not force:
            write_status(state="paused", detail=tr("Paused", "일시정지됨"), **base)
            return {"message": "paused"}
        if cfg.collect_only:  # even "process now": sorting belongs to the other Mac
            write_status(state="collecting", detail=tr("Only collecting notes; another Mac sorts them",
                                                       "메모만 받는 중 · 정리는 다른 Mac에서"),
                         last_run_at=iso(now()), last_error=None, other_processor=None,
                         inbox_blocks=remaining_blocks(cfg, 0), **base)
            return {"message": "collect_only"}
        request = processor.claim_request()
        if request.exists():
            request.unlink()
            processor.claim(cfg, force=True)
        owner = processor.other(cfg)
        if owner:
            hours = processor.age_hours(owner)
            ago = tr(f"{int(hours * 60)} min", f"{int(hours * 60)}분") if hours < 1 else tr(f"{int(hours)} h", f"{int(hours)}시간")
            write_status(state="blocked", other_processor=owner.get("name") or "?",
                         detail=tr(f"{owner.get('name')} sorted this vault {ago} ago, so this Mac doesn't (no double sorting)",
                                   f"{owner.get('name')}이(가) {ago} 전에 이 vault를 정리해서, 이 Mac은 정리하지 않아요 (중복 방지)"),
                         last_run_at=iso(now()), last_error=None, inbox_blocks=remaining_blocks(cfg, 0), **base)
            return {"message": "blocked"}
        processor.claim(cfg)
        run = Run(cfg, engine=engine, force=force)
        if quick:
            run.log(tr(f"Added {quick} quick note(s) to the inbox", f"빠른 메모 {quick}개를 inbox에 추가"))
        result = run.execute()
        state = run.state
        bump(state, "runs")
        if result.get("processed"):
            write_status(last_processed_at=iso(run.t))
        save_state(state)
        write_status(
            state="waiting" if result.get("held") and not result.get("processed") else "idle",
            detail=result["message"],
            last_run_at=iso(run.t),
            last_error=None,
            inbox_blocks=remaining_blocks(cfg, result["blocks"]),
            today=state["stats"].get(run.t.strftime("%Y-%m-%d"), {}),
            recent=list(reversed(state["history"][-10:])),
            other_processor=None,
            **base,
        )
        return result
    except (EngineError, OSError) as exc:
        state = load_state()
        bump(state, "errors")
        save_state(state)
        write_status(state="error", detail=tr("Error", "오류"), last_error=str(exc), last_run_at=iso(now()), **base)
        try:
            Run(cfg, engine=engine).log(tr("Error", "오류") + f": {exc}")
        except Exception:
            pass
        raise
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
