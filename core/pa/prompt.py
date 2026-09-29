"""Prompt construction for the planning call.

The model has no file access, so the prompt carries everything it needs: the
blocks, related notes found in the local index, recent history, rules, and the
folder outline.
"""

from typing import Any, Dict, List, Optional

from .config import Config
from .index import Searcher
from .inbox import Block
from .mention import resolve
from .state import now
from .vault import folder_tree, read_rules

WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def _block_section(cfg: Config, block: Block, searcher: Searcher, history: List[Dict[str, Any]]) -> str:
    context = block.text + " " + " ".join(h["title"] for h in history[-3:])
    found = searcher.search(context, cfg.candidates_per_block)
    lines = "\n".join(f"- {searcher.describe(rel)}" for rel in found) or "- (no related notes)"
    section = f'<block id="{block.id}">\n{block.text}\n</block>\nExisting notes that look related (local search results):\n{lines}'
    targets = _targets(block.text, searcher)
    if targets:
        section += "\nWhere the user said to record this, with @:\n" + targets
    return section


def _targets(text: str, searcher: Searcher) -> str:
    lines = []
    for kind, path in resolve(text, searcher.notes):
        if kind == "note":
            lines.append(f"- note {searcher.describe(path)}")
            continue
        inside = sorted((r for r in searcher.notes if r.startswith(path + "/")),
                        key=lambda r: -searcher.notes[r].get("mtime", 0))
        lines.append(f"- folder `{path}/` (create new notes inside this folder; to append, pick one of the notes below)")
        lines.extend(f"  - {searcher.describe(r)}" for r in inside[:5])
    return "\n".join(lines)


def build_prompt(cfg: Config, blocks: List[Block], history: List[Dict[str, Any]], searcher: Searcher,
                 groups: Optional[List[List[str]]] = None) -> str:
    t = now()
    today = f"{t.strftime('%Y-%m-%d %H:%M')} ({WEEKDAYS[t.weekday()]}, UTC{t.strftime('%z')})"
    block_text = "\n\n".join(_block_section(cfg, b, searcher, history) for b in blocks)
    if groups:
        block_text += "\n\n### Blocks written as one note\n" + "\n".join(
            f"- {', '.join(g)}: one note the user wrote in one go. Always put them in a single item; "
            "a request line (`Request:` or `요청:`) in the first block applies to the whole note."
            for g in groups
        )
    if history:
        hist = "\n".join(
            f"- id={h['id']} | {h['time']} | {h['kind']} | {h['title']} | recorded in: {', '.join(h['targets']) or '-'}"
            for h in history
        )
    else:
        hist = "(none)"

    return f"""You are the user's personal assistant. The user writes free-form notes into an inbox file in a folder of markdown notes (the vault). Analyze the note blocks below and make a plan (JSON) of what to record where.

Current time: {today}
You have no file access. All you know about the vault is the information given below (related notes per block, the folder structure, the processing history). A program that receives your plan does the actual writing.

## Blocks to process
{block_text}

## Recent history (for recognizing continuations, oldest → newest)
{hist}

## User rules (always follow)
{read_rules(cfg)}

## Vault folder structure (folder/ (note count), down to depth {cfg.tree_depth})
{folder_tree(cfg)}

## Output
- Put blocks that belong together into one item. Every block id must appear in the block_ids of exactly one item.
- kind: todo | project | idea | meeting | note | calendar | other
- title: a short one-line summary.
- continues: the id of the recent history entry this item continues, or null. If it continues one, append to that entry's recorded location.
- confidence: 0.0–1.0, an honest estimate of the chance that the classification, placement, and interpretation are right. Give it low if you guessed because no related note was found, the original is ambiguous, or you inferred a date.
- properties: values for the new note's frontmatter (the program writes the frontmatter itself).
  - type: list of note kinds (e.g. ["idea"], ["meeting"], ["project-note"])
  - project: the related project's name (usually a folder name under 01-projects), or null
  - tags: only if needed, without #
- actions (an item can have several):
  - todo: content = lines starting with `- [ ] `. path = null for the shared todo list; a path only when putting it in a project note.
  - create: a new note. path = vault-relative path (.md), content = body without frontmatter. If the file already exists, use append.
  - append: add to the end of an existing note. path = an existing note path listed above, content = what to add. Don't repeat existing content.
  - calendar: a calendar candidate. path = null, content = one line in the calendar rules' format.
  - review: when the placement is uncertain or a judgment call is needed. path = null, content = a summary of the original, the suggested location, and the reason.
- Only append to existing notes listed above or to locations in the processing history. Never append to a path you can't confirm exists.
- Don't drop simple notes with little to record; send them to a suitable note or to review.
- A line starting with `Request:` (or `요청:`) is an instruction the user gave you directly. It isn't content to record, so leave it out of the output, and use it to decide the classification, placement, and format (e.g. turn it into meeting notes, add it to a specific note, summarize, todos only). If the instruction conflicts with the constraints below or can't be followed, send it to review and give the reason.
- A block headed `## Meeting notes (start–end)` (or `## 미팅 메모 (…)`) was written during a meeting; treat it as one meeting. A leading `continued:` (or `이어서:`) marks a follow-up to an earlier note.
- If there is a location the user set with `@`, it's the user's choice, so follow it: for a note, append to that note; for a folder, append to a note in that folder or create a new note there. Don't copy the `@…` notation itself into the output. An `@…` whose name wasn't found is only a hint.
- Don't leave out or invent information from the original (when a request asks for a summary you may shorten it, but never make up facts). Write the output in the language the user wrote the note in.
- Paths under {cfg.assistant_dir}/ and the inbox file can't be used as a path.
- reason: a short reason for choosing that action.
"""
