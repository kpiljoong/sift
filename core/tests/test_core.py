import contextlib
import io
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

_TMP_HOME = tempfile.mkdtemp(prefix="pa-home-")
os.environ["PA_HOME"] = _TMP_HOME
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pa import vault  # noqa: E402
from pa.config import Config  # noqa: E402
from pa.engine import run_once  # noqa: E402
from pa.inbox import remove_blocks, split_blocks  # noqa: E402
from pa.state import load_state, read_status  # noqa: E402


class FakeEngine:
    def __init__(self, plan_fn):
        self.plan_fn = plan_fn
        self.calls = []

    def plan(self, prompt):
        self.calls.append(prompt)
        return self.plan_fn(prompt)


def ids_in(prompt):
    import re

    return re.findall(r'<block id="([0-9a-f]{8})">', prompt)


class InboxTests(unittest.TestCase):
    def test_split_on_blank_lines_and_headings(self):
        text = "---\ntags: x\n---\n첫 메모\n둘째 줄\n\n#태그는 헤딩 아님\n## 회의\n내용\n"
        blocks = split_blocks(text)
        self.assertEqual([b.text for b in blocks], ["첫 메모\n둘째 줄", "#태그는 헤딩 아님", "## 회의\n내용"])

    def test_remove_exact_blocks_only(self):
        text = "a\n\nb\n\nc\n"
        new, removed = remove_blocks(text, ["b", "zzz"])
        self.assertEqual(new, "a\n\nc\n")
        self.assertEqual(removed, {"b"})

    def test_remove_everything_keeps_frontmatter(self):
        new, _ = remove_blocks("---\nx: 1\n---\na\n", ["a"])
        self.assertEqual(new, "---\nx: 1\n---\n")


class EngineTests(unittest.TestCase):
    def setUp(self):
        for f in Path(_TMP_HOME).iterdir():
            shutil.rmtree(f) if f.is_dir() else f.unlink()
        self.vault = Path(tempfile.mkdtemp(prefix="pa-vault-"))
        (self.vault / "01-projects" / "alpha").mkdir(parents=True)
        (self.vault / "01-projects" / "alpha" / "notes.md").write_text("기존 내용\n", encoding="utf-8")
        # Korean keeps the vault text of earlier releases; LanguageTests covers English
        self.cfg = Config(vault=str(self.vault), dry_run=False, last_block_hold_minutes=30, language="ko")
        vault.init_assistant_dir(self.cfg)
        self.inbox = self.cfg.inbox_path
        self.inbox.parent.mkdir(parents=True)
        self.inbox.touch()

    def write_inbox(self, text, age_minutes=10):
        self.inbox.write_text(text, encoding="utf-8")
        t = time.time() - age_minutes * 60
        os.utime(self.inbox, (t, t))

    def read(self, rel):
        return (self.vault / rel).read_text(encoding="utf-8")

    def todo_plan(self, prompt):
        return {
            "items": [
                {"block_ids": [i], "kind": "todo", "title": "t", "continues": None,
                 "actions": [{"type": "todo", "path": None, "content": f"- [ ] 할 일 {i}", "reason": "r"}]}
                for i in ids_in(prompt)
            ]
        }

    def test_waits_for_quiet_time(self):
        self.write_inbox("치과 전화\n", age_minutes=1)
        engine = FakeEngine(self.todo_plan)
        result = run_once(engine=engine, cfg=self.cfg)
        self.assertEqual(engine.calls, [])
        self.assertIn("대기", result["message"])
        self.assertEqual(read_status()["state"], "waiting")

    def test_last_block_is_held_and_rest_processed(self):
        self.write_inbox("치과 전화\n\n보고서 쓰기\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        self.assertEqual(len(ids_in(engine.calls[0])), 1)
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "보고서 쓰기\n")
        self.assertEqual(read_status()["inbox_blocks"], 1)  # what is left, not what was there
        todo = self.read("99-assistant/todo.md")
        self.assertIn("- [ ] 할 일", todo)
        self.assertIn("[[99-assistant/inbox-archive/", todo)
        archive = next((self.vault / "99-assistant" / "inbox-archive").iterdir()).read_text(encoding="utf-8")
        self.assertIn("치과 전화", archive)
        self.assertTrue(any((self.vault / "99-assistant" / "backup").iterdir()))

    def test_run_now_processes_everything_immediately(self):
        self.write_inbox("치과 전화\n\n보고서 쓰기\n", age_minutes=0)
        engine = FakeEngine(self.todo_plan)
        run_once(force=True, engine=engine, cfg=self.cfg)
        self.assertEqual(len(ids_in(engine.calls[0])), 2)
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "")

    def test_last_block_processed_after_hold(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("치과 전화\n")
        run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "")

    def test_inbox_change_during_analysis_discards_plan(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("치과 전화\n")

        def plan(prompt):
            self.inbox.write_text("치과 전화\n이어서 쓰는 중\n", encoding="utf-8")
            return self.todo_plan(prompt)

        result = run_once(engine=FakeEngine(plan), cfg=self.cfg)
        self.assertIn("재시도", result["message"])
        self.assertNotIn("할 일", self.read("99-assistant/todo.md"))
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "치과 전화\n이어서 쓰는 중\n")

    def test_unsafe_paths_go_to_review_and_existing_notes_are_not_overwritten(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("메모\n")

        def plan(prompt):
            i = ids_in(prompt)[0]
            return {"items": [{"block_ids": [i], "kind": "note", "title": "t", "continues": None, "actions": [
                {"type": "create", "path": "../escape.md", "content": "탈출", "reason": "r"},
                {"type": "create", "path": ".obsidian/x.md", "content": "숨김", "reason": "r"},
                {"type": "append", "path": "00-inbox/active.md", "content": "inbox", "reason": "r"},
                {"type": "create", "path": "01-projects/alpha/notes.md", "content": "새 내용", "reason": "r"},
            ]}]}

        run_once(engine=FakeEngine(plan), cfg=self.cfg)
        self.assertFalse((self.vault.parent / "escape.md").exists())
        self.assertFalse((self.vault / ".obsidian" / "x.md").exists())
        notes = self.read("01-projects/alpha/notes.md")
        self.assertTrue(notes.startswith("기존 내용\n"))
        self.assertIn("새 내용", notes)
        review = next(p for p in (self.vault / "99-assistant" / "review").iterdir()).read_text(encoding="utf-8")
        self.assertEqual(review.count("안전 규칙 위반"), 3)

    def test_blocks_missing_from_plan_go_to_review(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("하나\n\n둘\n")
        run_once(engine=FakeEngine(lambda p: {"items": []}), cfg=self.cfg)
        review = next((self.vault / "99-assistant" / "review").iterdir()).read_text(encoding="utf-8")
        self.assertIn("하나", review)
        self.assertIn("둘", review)

    def test_item_without_actions_goes_to_review(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("이미 적어둔 것\n")
        run_once(engine=FakeEngine(lambda p: {"items": [
            {"block_ids": ids_in(p), "kind": "note", "title": "t", "continues": None, "confidence": 0.99,
             "properties": {"type": [], "project": None, "tags": []}, "actions": []}]}), cfg=self.cfg)
        review = next((self.vault / "99-assistant" / "review").iterdir()).read_text(encoding="utf-8")
        self.assertIn("이미 적어둔 것", review)

    def test_dry_run_writes_report_only_once(self):
        self.cfg.dry_run = True
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("치과 전화\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        run_once(engine=engine, cfg=self.cfg)
        self.assertEqual(len(engine.calls), 1)
        self.assertEqual(load_state()["history"], [])
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "치과 전화\n")
        self.assertNotIn("할 일", self.read("99-assistant/todo.md"))
        report = [p for p in (self.vault / "99-assistant" / "review").iterdir() if p.name.startswith("dry-run")]
        self.assertIn("할 일", report[0].read_text(encoding="utf-8"))

    def test_created_note_gets_frontmatter_from_code(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("alpha 회의 메모\n")

        def plan(prompt):
            i = ids_in(prompt)[0]
            return {"items": [{"block_ids": [i], "kind": "meeting", "title": "t", "continues": None,
                               "confidence": 0.9,
                               "properties": {"type": ["meeting"], "project": "alpha", "tags": ["#weekly sync"]},
                               "actions": [{"type": "create", "path": "01-projects/alpha/meetings/m.md",
                                            "content": "---\ntitle: ignored\n---\n# 회의\n내용", "reason": "r"}]}]}

        run_once(engine=FakeEngine(plan), cfg=self.cfg)
        note = self.read("01-projects/alpha/meetings/m.md")
        self.assertTrue(note.startswith("---\ntype:\n  - meeting\nproject: alpha\ndate: "))
        self.assertIn("tags:\n  - weekly-sync\n", note)
        self.assertIn('categories: "[[Meetings]]"', note)
        self.assertIn("source: assistant\nconfidence: 0.90\n---\n\n# 회의\n내용", note)
        self.assertNotIn("title: ignored", note)
        self.assertNotIn("#assistant/review", note)

    def create_plan(self, path):
        def plan(prompt):
            return {"items": [{"block_ids": ids_in(prompt), "kind": "project", "title": "t", "continues": None,
                               "confidence": 0.9, "properties": {"type": ["project"]},
                               "actions": [{"type": "create", "path": path, "content": "내용", "reason": "r"}]}]}
        return plan

    def test_new_project_folder_is_created_and_flagged(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("Tramio 출시 준비\n")
        run_once(engine=FakeEngine(self.create_plan("01-projects/tramio/출시 준비.md")), cfg=self.cfg)
        note = self.read("01-projects/tramio/출시 준비.md")
        self.assertIn("  - assistant/review\n", note)  # frontmatter tag: shows up for review
        self.assertTrue(note.rstrip().endswith("#assistant/review"))
        log = next((self.vault / "99-assistant" / "log").glob("*.md")).read_text(encoding="utf-8")
        self.assertIn("새 폴더 `01-projects/tramio/`", log)

    def test_similar_existing_folder_is_reused(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("alpha 메모\n")
        run_once(engine=FakeEngine(self.create_plan("01-projects/Alphas/메모.md")), cfg=self.cfg)
        self.assertTrue((self.vault / "01-projects" / "alpha" / "메모.md").exists())
        self.assertFalse((self.vault / "01-projects" / "Alphas").exists())
        self.assertNotIn("#assistant/review", self.read("01-projects/alpha/메모.md"))

    def test_low_confidence_is_flagged(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("애매한 메모\n")

        def plan(prompt):
            i = ids_in(prompt)[0]
            return {"items": [{"block_ids": [i], "kind": "todo", "title": "t", "continues": None, "confidence": 0.3,
                               "properties": {"type": [], "project": None, "tags": []},
                               "actions": [
                                   {"type": "todo", "path": None, "content": "- [ ] 뭔가 하기", "reason": "r"},
                                   {"type": "append", "path": "01-projects/alpha/notes.md", "content": "추가", "reason": "r"},
                               ]}]}

        run_once(engine=FakeEngine(plan), cfg=self.cfg)
        self.assertIn("- [ ] 뭔가 하기 [[", self.read("99-assistant/todo.md"))
        self.assertIn("#assistant/review", self.read("99-assistant/todo.md"))
        notes = self.read("01-projects/alpha/notes.md")
        self.assertTrue(notes.startswith("기존 내용\n"))
        self.assertIn("confidence 0.30", notes)
        self.assertIn("#assistant/review", notes)

    def test_prompt_uses_index_and_respects_ignore(self):
        self.cfg.last_block_hold_minutes = 0
        (self.vault / "02-areas" / "private").mkdir(parents=True)
        (self.vault / "02-areas" / "private" / "alpha-secret.md").write_text("alpha 비밀\n", encoding="utf-8")
        with (self.vault / "99-assistant" / ".assistantignore").open("a", encoding="utf-8") as fh:
            fh.write("02-areas/private\n")
        self.write_inbox("alpha 대시보드 아이디어\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        prompt = engine.calls[0]
        self.assertIn("`01-projects/alpha/notes.md`", prompt)
        self.assertNotIn("alpha-secret", prompt)
        self.assertNotIn("private", prompt)

    def test_at_targets_are_resolved_into_the_prompt(self):
        self.cfg.last_block_hold_minutes = 0
        (self.vault / "03-resources").mkdir()
        (self.vault / "03-resources" / "Reading List.md").write_text("# 읽을 거리\n", encoding="utf-8")
        (self.vault / "02-areas" / "private").mkdir(parents=True)
        (self.vault / "02-areas" / "private" / "secret.md").write_text("비밀\n", encoding="utf-8")
        with (self.vault / "99-assistant" / ".assistantignore").open("a", encoding="utf-8") as fh:
            fh.write("02-areas/private\n")
        self.write_inbox("대시보드 개선 @[[03-resources/Reading List]]\n\n"
                         "배포 체크 @alpha\n\n"
                         "메일 a@alpha.com @[[02-areas/private/secret]] @secret @없는이름\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        blocks = engine.calls[0].split("## Blocks to process")[1].split("## Recent history")[0].split("<block id=")
        self.assertIn("- note `03-resources/Reading List.md` | 읽을 거리", blocks[1])
        self.assertIn("- folder `01-projects/alpha/`", blocks[2])
        self.assertIn("  - `01-projects/alpha/notes.md`", blocks[2])
        self.assertNotIn("with @:", blocks[3])  # email, ignored note and unknown name resolve to nothing

    def test_mention_forms(self):
        from pa.mention import resolve

        notes = {"01-projects/alpha/README.md": {"title": "Alpha 프로젝트"}, "notes/beta.md": {"title": "beta"}}
        self.assertEqual(resolve("@[[01-projects/alpha/]] @[[notes/beta]]", notes),
                         [("folder", "01-projects/alpha"), ("note", "notes/beta.md")])
        self.assertEqual(resolve("(@Beta, @readme.", notes), [("note", "notes/beta.md"), ("note", "01-projects/alpha/README.md")])
        self.assertEqual(resolve("x@beta @[[nope]] @[[notes/beta.md]]", notes), [("note", "notes/beta.md")])
        self.assertEqual(resolve("@notes/ @beta/", notes), [("folder", "notes")])
        self.assertEqual(resolve("@01-projects/alpha/ @notes/beta", notes),
                         [("folder", "01-projects/alpha"), ("note", "notes/beta.md")])

    def test_pending_removal_is_retried(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("치과 전화\n\n다른 메모\n")
        state = load_state()
        state["pending_removal"] = ["치과 전화"]
        from pa.state import save_state

        save_state(state)
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        self.assertEqual(len(ids_in(engine.calls[0])), 1)
        self.assertNotIn("치과 전화", engine.calls[0].split("## Blocks to process")[1].split("##")[0])
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "")

    def test_inbox_outside_vault_is_rejected(self):
        from pa.config import ConfigError

        self.assertRaises(ConfigError, Config().check_locations)  # fresh install: no vault chosen yet
        for bad in ("../active.md", "/tmp/active.md", "00-inbox/active.txt", "99-assistant/active.md"):
            self.cfg.inbox = bad
            with self.assertRaises(ConfigError):
                run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
            self.assertEqual(read_status()["state"], "error")

    def test_missing_inbox_is_an_error_not_created(self):
        from pa.config import ConfigError

        self.inbox.unlink()
        with self.assertRaises(ConfigError):
            run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
        self.assertFalse(self.inbox.exists())
        self.assertIn("inbox 파일이 없습니다", read_status()["last_error"])

    def test_switching_vault_resets_history(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("치과 전화\n")
        run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
        self.assertEqual(len(load_state()["history"]), 1)

        other = Path(tempfile.mkdtemp(prefix="pa-vault2-"))
        (other / "00-inbox").mkdir()
        (other / "00-inbox" / "active.md").touch()
        cfg2 = Config(vault=str(other), dry_run=False, language="ko")
        run_once(engine=FakeEngine(self.todo_plan), cfg=cfg2)
        state = load_state()
        self.assertEqual(state["history"], [])
        self.assertEqual(state["vault"], str(other))
        self.assertTrue((other / "99-assistant" / "todo.md").exists())

    def test_scheduled_check_waits_for_interval(self):
        from pa.config import config_path, save_config
        from pa.engine import check_due, mark_checked

        self.cfg.check_interval_minutes = 5
        save_config(self.cfg)
        marker = Path(_TMP_HOME) / "last-check"
        self.assertTrue(check_due(self.cfg))  # never checked
        mark_checked()
        t = time.time()
        old = t - 600
        os.utime(config_path(), (old, old))
        self.assertFalse(check_due(self.cfg, at=t + 60))
        self.assertTrue(check_due(self.cfg, at=t + 5 * 60))
        os.utime(config_path(), (t + 1, t + 1))  # settings changed after the last check
        self.assertTrue(check_due(self.cfg, at=t + 60))
        os.utime(config_path(), (old, old))
        Path(_TMP_HOME, "run-now").touch()
        self.assertTrue(check_due(self.cfg, at=t + 60))

    def test_quick_notes_are_appended_and_skip_waiting(self):
        from pa.engine import check_due, ingest_quick_notes, mark_checked, quick_dir

        self.write_inbox("쓰는 중인 메모", age_minutes=0)  # editor not quiet, and it is the last block
        quick_dir().mkdir(exist_ok=True)
        (quick_dir() / "20260929-100000-a.md").write_text("치과 예약\n\n회의 준비\n자료 확인\n", encoding="utf-8")
        mark_checked()
        self.assertTrue(check_due(self.cfg))  # a waiting quick note is always due
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        self.assertEqual(list(quick_dir().glob("*.md")), [])
        prompt = engine.calls[0].split("## Blocks to process")[1]
        self.assertIn("치과 예약", prompt)
        self.assertIn("회의 준비\n자료 확인", prompt)
        self.assertNotIn("쓰는 중인 메모", prompt)
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "쓰는 중인 메모\n")
        self.assertEqual(ingest_quick_notes(self.cfg), 0)

    def test_quick_note_with_request_is_one_group(self):
        import json as _json

        from pa.engine import quick_dir

        quick_dir().mkdir(exist_ok=True)
        note = {"text": "주간 싱크\n- 배포 일정 논의\n\n## 결정\n- 금요일 배포", "request": "회의록으로 정리"}
        (quick_dir() / "1.json").write_text(_json.dumps(note, ensure_ascii=False), encoding="utf-8")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        prompt = engine.calls[0]
        ids = ids_in(prompt)
        self.assertEqual(len(ids), 2)
        self.assertIn("요청: 회의록으로 정리\n주간 싱크", prompt)
        self.assertIn(f"- {', '.join(ids)}: one note the user wrote in one go", prompt)


    def test_resort_requeues_original_and_records_correction(self):
        import json as _json

        from pa.engine import quick_dir

        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("alpha 배포 스크립트 점검\n\n회의 메모 한 줄\n")
        run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
        entry = load_state()["history"][0]
        self.assertEqual(entry["ids"], [entry["id"]])

        quick_dir().mkdir(exist_ok=True)
        note = {"text": "", "request": "alpha 프로젝트 문서로", "resort": entry}
        (quick_dir() / "1.json").write_text(_json.dumps(note, ensure_ascii=False), encoding="utf-8")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, cfg=self.cfg)
        prompt = engine.calls[0]
        self.assertIn("요청: 다시 정리 — 이전에 99-assistant/todo.md에 정리했지만 사용자가 바로잡음: alpha 프로젝트 문서로", prompt)
        self.assertIn("alpha 배포 스크립트 점검", prompt.split("## Blocks to process")[1])
        corrections = self.read("99-assistant/rules/corrections.md")
        self.assertIn("바로잡음: alpha 프로젝트 문서로", corrections)
        self.assertIn("rules/corrections.md", prompt)  # learned rules go to every later run
        self.assertIn(f"할 일 {entry['id']}", self.read("99-assistant/todo.md"))  # the earlier entry stays

    def low_todo_plan(self, prompt, confidence=0.3):
        plan = self.todo_plan(prompt)
        for item in plan["items"]:
            item["confidence"] = confidence
        return plan

    def sure_todo_plan(self, prompt):
        return self.low_todo_plan(prompt, 0.9)

    def test_review_list_follows_the_vault(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("애매한 할 일\n\n확실한 할 일\n")
        ids = []

        def plan(prompt):
            ids.extend(ids_in(prompt))
            p = self.todo_plan(prompt)
            p["items"][0]["confidence"] = 0.3
            p["items"][1]["confidence"] = 0.9
            return p

        run_once(engine=FakeEngine(plan), cfg=self.cfg)
        pending = read_status()["review"]
        self.assertEqual([e["id"] for e in pending], [ids[0]])

        todo = self.vault / "99-assistant" / "todo.md"
        todo.write_text(todo.read_text(encoding="utf-8").replace(" #assistant/review", ""), encoding="utf-8")
        self.write_inbox("다른 메모\n")
        run_once(engine=FakeEngine(self.sure_todo_plan), cfg=self.cfg)
        self.assertEqual(read_status()["review"], [])  # the user removed the tag: settled

    def test_resort_marks_earlier_todo_as_moved_and_settles_it(self):
        import json as _json

        from pa.engine import quick_dir

        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("alpha 배포 스크립트 점검\n")
        run_once(engine=FakeEngine(self.low_todo_plan), cfg=self.cfg)
        entry = load_state()["history"][0]
        self.assertEqual(len(read_status()["review"]), 1)

        quick_dir().mkdir(exist_ok=True)
        note = {"text": "", "request": "alpha 프로젝트 문서로", "resort": entry}
        (quick_dir() / "1.json").write_text(_json.dumps(note, ensure_ascii=False), encoding="utf-8")
        run_once(engine=FakeEngine(self.create_plan("01-projects/alpha/배포.md")), cfg=self.cfg)
        todo = self.read("99-assistant/todo.md")
        line = next(l for l in todo.splitlines() if f"할 일 {entry['id']}" in l)
        self.assertTrue(line.startswith("- [ ] 할 일"))  # kept, not rewritten
        self.assertTrue(line.endswith(" ↪ 옮김 [[01-projects/alpha/배포]]"))
        self.assertEqual(read_status()["review"], [])
        self.assertEqual(load_state()["resorts"], {})

    def test_review_list_starts_from_history_on_upgrade(self):
        self.cfg.last_block_hold_minutes = 0
        self.write_inbox("애매한 할 일\n")
        run_once(engine=FakeEngine(self.low_todo_plan), cfg=self.cfg)
        from pa.state import save_state
        state = load_state()
        state["review"], state["review_seeded"] = [], False  # as left by 0.6.5
        save_state(state)
        self.write_inbox("다른 메모\n")
        run_once(engine=FakeEngine(self.sure_todo_plan), cfg=self.cfg)
        self.assertEqual(len(read_status()["review"]), 1)


class ProcessorTests(unittest.TestCase):
    """Two Macs syncing one vault: only one of them sorts it."""

    setUp = EngineTests.setUp
    write_inbox = EngineTests.write_inbox
    read = EngineTests.read
    todo_plan = EngineTests.todo_plan

    def other_marker(self, hours_ago):
        import json as _json
        from datetime import timedelta

        from pa.state import iso, now

        (self.vault / "99-assistant" / "sift-processor.json").write_text(_json.dumps(
            {"id": "someone-else", "name": "MacBook", "at": iso(now() - timedelta(hours=hours_ago))}), encoding="utf-8")

    def marker(self):
        import json as _json

        return _json.loads(self.read("99-assistant/sift-processor.json"))

    def test_sorting_mac_marks_the_vault(self):
        from pa.processor import machine_id

        self.write_inbox("치과 전화\n")
        run_once(engine=FakeEngine(self.todo_plan), cfg=self.cfg)
        self.assertEqual(self.marker()["id"], machine_id())

    def test_another_mac_sorting_recently_stops_this_one(self):
        self.other_marker(hours_ago=1)
        self.write_inbox("치과 전화\n")
        engine = FakeEngine(self.todo_plan)
        self.assertEqual(run_once(engine=engine, force=True, cfg=self.cfg)["message"], "blocked")
        self.assertEqual(engine.calls, [])
        status = read_status()
        self.assertEqual((status["state"], status["other_processor"]), ("blocked", "MacBook"))
        self.assertEqual(self.marker()["id"], "someone-else")
        self.assertEqual(self.inbox.read_text(encoding="utf-8"), "치과 전화\n")

    def test_stale_marker_is_taken_over(self):
        from pa.processor import machine_id

        self.other_marker(hours_ago=30)
        self.write_inbox("치과 전화\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, force=True, cfg=self.cfg)
        self.assertEqual(len(engine.calls), 1)
        self.assertEqual(self.marker()["id"], machine_id())

    def test_sort_on_this_mac_request_takes_over(self):
        from pa.processor import claim_request, machine_id

        self.other_marker(hours_ago=1)
        claim_request().touch()
        self.write_inbox("치과 전화\n")
        engine = FakeEngine(self.todo_plan)
        run_once(engine=engine, force=True, cfg=self.cfg)
        self.assertEqual(len(engine.calls), 1)
        self.assertEqual(self.marker()["id"], machine_id())
        self.assertFalse(claim_request().exists())
        self.assertIsNone(read_status()["other_processor"])

    def test_collect_only_adds_quick_notes_but_never_sorts(self):
        import json as _json

        from pa.engine import quick_dir

        quick_dir().mkdir(exist_ok=True)
        (quick_dir() / "1.json").write_text(_json.dumps({"text": "치과 예약"}), encoding="utf-8")
        self.cfg.collect_only = True
        engine = FakeEngine(self.todo_plan)
        self.assertEqual(run_once(engine=engine, force=True, cfg=self.cfg)["message"], "collect_only")
        self.assertEqual(engine.calls, [])
        self.assertIn("치과 예약", self.inbox.read_text(encoding="utf-8"))
        self.assertEqual(read_status()["state"], "collecting")
        self.assertFalse((self.vault / "99-assistant" / "sift-processor.json").exists())


class LanguageTests(unittest.TestCase):
    def setUp(self):
        for f in Path(_TMP_HOME).iterdir():
            shutil.rmtree(f) if f.is_dir() else f.unlink()
        self.vault = Path(tempfile.mkdtemp(prefix="pa-vault-"))
        (self.vault / "00-inbox").mkdir()
        self.inbox = self.vault / "00-inbox" / "active.md"
        self.write_inbox("call the dentist\n")

    def write_inbox(self, text, age_minutes=10):
        self.inbox.write_text(text, encoding="utf-8")
        t = time.time() - age_minutes * 60
        os.utime(self.inbox, (t, t))

    def read(self, rel):
        return (self.vault / rel).read_text(encoding="utf-8")

    @staticmethod
    def review_plan(prompt):
        return {"items": [{"block_ids": ids_in(prompt), "kind": "other", "title": "t", "confidence": 0.2,
                           "actions": [{"type": "review", "path": None, "content": "where?", "reason": "r"}]}]}

    def run_with(self, language, **kw):
        cfg = Config(vault=str(self.vault), dry_run=False, last_block_hold_minutes=0, language=language, **kw)
        engine = FakeEngine(self.review_plan)
        result = run_once(engine=engine, cfg=cfg)
        return engine, result

    def test_default_is_english(self):
        self.assertEqual(Config().language, "en")
        engine, result = self.run_with(Config().language)
        self.assertEqual(result["message"], "Processed 1 block(s)")
        self.assertEqual(read_status()["detail"], "Processed 1 block(s)")
        review = next((self.vault / "99-assistant" / "review").glob("*.md")).read_text(encoding="utf-8")
        self.assertIn(" Needs review\nwhere?", review)
        self.assertIn("|source]]", review)
        self.assertTrue(self.read("99-assistant/rules/todo-format.md").startswith("# Todo format rules"))
        self.assertEqual(self.read("99-assistant/calendar-queue.md"), "# Calendar queue\n")
        self.assertIn("name: Needs review (new notes)", self.read("99-assistant/assistant.base"))
        log = next((self.vault / "99-assistant" / "log").glob("*.md")).read_text(encoding="utf-8")
        self.assertIn("needs review", log)
        self.assertIn("## Blocks to process", engine.calls[0])
        self.assertIn("# Todo format rules", engine.calls[0])

    def test_korean_keeps_korean_text(self):
        _, result = self.run_with("ko")
        self.assertEqual(result["message"], "블록 1개 처리")
        self.assertEqual(read_status()["detail"], "블록 1개 처리")
        review = next((self.vault / "99-assistant" / "review").glob("*.md")).read_text(encoding="utf-8")
        self.assertIn(" 확인 필요\nwhere?", review)
        self.assertIn("|원문]]", review)
        self.assertTrue(self.read("99-assistant/rules/todo-format.md").startswith("# Todo 형식 규칙"))
        self.assertEqual(self.read("99-assistant/calendar-queue.md"), "# 일정 등록 대기\n")
        self.assertIn("name: 확인 필요 (새 문서)", self.read("99-assistant/assistant.base"))

    def test_existing_files_are_not_replaced_when_language_changes(self):
        self.run_with("ko")
        self.write_inbox("second note\n")
        self.run_with("en")
        self.assertTrue(self.read("99-assistant/rules/todo-format.md").startswith("# Todo 형식 규칙"))
        self.assertEqual(self.read("99-assistant/calendar-queue.md"), "# 일정 등록 대기\n")

    def test_request_line_in_either_language(self):
        import json as _json

        from pa.engine import quick_dir

        for language, prefix in (("en", "Request:"), ("ko", "요청:")):
            self.write_inbox("")
            quick_dir().mkdir(exist_ok=True)
            note = {"text": "weekly sync\n\n## decisions\n- ship friday", "request": "make meeting notes"}
            (quick_dir() / "1.json").write_text(_json.dumps(note), encoding="utf-8")
            engine, _ = self.run_with(language)
            prompt = engine.calls[0]
            self.assertIn(f"{prefix} make meeting notes\nweekly sync", prompt)
            self.assertEqual(len(ids_in(prompt)), 2)
            self.assertIn("### Blocks written as one note", prompt)
        # typed by hand, both prefixes reach the model, which is told to honour either
        self.write_inbox("요청: 회의록으로\n주간 싱크\n\nRequest: todos only\nbuy milk\n")
        engine, _ = self.run_with("en")
        prompt = engine.calls[0]
        self.assertIn("요청: 회의록으로", prompt)
        self.assertIn("Request: todos only", prompt)
        self.assertIn("A line starting with `Request:` (or `요청:`)", prompt)
        self.assertIn("`## Meeting notes (start–end)` (or `## 미팅 메모 (…)`)", prompt)

    def test_invalid_language_falls_back_to_english(self):
        import json as _json

        from pa.cli import main
        from pa.config import config_path, load_config

        self.assertEqual(Config(language="fr").language, "en")
        config_path().write_text(_json.dumps({"vault": str(self.vault), "language": "xx"}), encoding="utf-8")
        self.assertEqual(load_config().language, "en")
        with contextlib.redirect_stdout(io.StringIO()):
            main(["set", "language", "ko"])
            self.assertEqual(load_config().language, "ko")
            main(["set", "language", "de"])
        self.assertEqual(_json.loads(config_path().read_text(encoding="utf-8"))["language"], "en")

    def test_config_language(self):
        import json as _json

        from pa.config import config_path, load_config

        config_path().unlink(missing_ok=True)
        self.assertEqual(load_config().language, "en")  # a new config
        self.assertEqual(_json.loads(config_path().read_text(encoding="utf-8"))["language"], "en")
        # written by a version before the language choice, which was Korean only
        config_path().write_text(_json.dumps({"vault": str(self.vault)}), encoding="utf-8")
        self.assertEqual(load_config().language, "ko")

    def test_config_errors_follow_language(self):
        from pa.config import ConfigError

        self.inbox.unlink()
        for language, text in (("en", "The inbox file doesn't exist"), ("ko", "inbox 파일이 없습니다")):
            with self.assertRaises(ConfigError):
                self.run_with(language)
            self.assertIn(text, read_status()["last_error"])


if __name__ == "__main__":
    unittest.main()
