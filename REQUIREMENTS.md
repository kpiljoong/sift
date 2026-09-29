# Sift — Requirements (v1)

Settled: 2026-09-26

## 1. Goal

Write whatever comes to mind in a single free-form file (the inbox), and a background assistant analyzes it
and files it inside the markdown notes folder (the vault) as todos, notes, and calendar candidates.

- One input; the assistant does the sorting. The user never has to think about format or categories.
- Nothing is deleted.

## 2. Environment

| Item | Value |
|---|---|
| Target machine | Personal Mac (macOS 13 or later) |
| How it runs | A resident menu bar app (started at login by launchd) runs the core every minute, and the core decides whether a check is due (default every 2 minutes; see section 9). As a child process of the app, the core gets folder access under Sift's name |
| AI engine | Codex (`codex exec` headless, personal account). The engine layer is designed to be swappable; Claude support comes later |
| Vault path | Chosen by the user in settings (e.g. `~/Obsidian/MyVault`) |
| Inbox file | A `.md` file inside the vault (default: `00-inbox/active.md`) |
| Assistant folder | `<vault>/99-assistant/` |

## 3. Inbox processing

### 3.1 Input format
- Completely free-form. No rules.
- Processed in blocks (split on blank lines or headings).
- Optional hints (`continued:` / `이어서:`, `Request:` / `요청:`, etc.) are recognized but never required.

### 3.2 Not colliding with what's being written
| Rule | Detail |
|---|---|
| A. Quiet time | Processing starts only **5 minutes** after the file was last modified |
| B. Last block hold | The last block is processed only when it hasn't changed for **10 minutes** |
| C. Verify before modifying | Store a hash before processing → check again right before modifying the inbox → if even one character changed, leave the inbox alone this round and retry next round. Only text that exactly matches a processed block is removed |
| D. Move | Processed blocks move verbatim to `99-assistant/inbox-archive/YYYY-MM.md` |

- Right before modifying the inbox, a snapshot of the whole `active.md` is saved to `99-assistant/backup/` (the means of recovery, since the vault has no git).

### 3.3 Recognizing continuations
- When processing new blocks, the recent processing history (last 20 entries: summary + where they were written) goes to the AI along with them.
- The AI decides whether an item is new or a follow-up to an existing one; a follow-up is appended to the end of the existing note.

## 4. Output

### 4.1 Todo
In the Obsidian Tasks plugin format:
```
- [ ] content 📅 2026-09-30 #project/xxx [[link to the archived original]]
```
- Default location: `99-assistant/todo.md` (appended to the project's note when the project is clear)
- No duplicate todos.

### 4.2 Writing and filing notes
- One input file; the output is split into separate files by content (project / idea / meeting, etc.).
- The location is chosen from the vault's folder structure and local index search results (section 8).
- Only creating new files or **appending** to the end of existing files is allowed.
- When no location can be determined, the item goes to `99-assistant/review/`.

### 4.4 Frontmatter and confidence
- The code writes the frontmatter of new notes (the AI never writes YAML directly). The AI only picks the type, project, and tags values.
  ```yaml
  type: [idea]
  project: alpha        # only when there is one
  date: 2026-09-26
  tags: [...]           # only when there are any
  categories: "[[Meetings]]"   # only for meetings (works with Meetings.base)
  source: assistant
  confidence: 0.85
  ```
- The rules live in `99-assistant/rules/frontmatter.md`.
- Appending to an existing note never touches its frontmatter.
- Every item gets a confidence (0–1). Below the threshold (`review_threshold`, default 0.7):
  - New notes: the frontmatter confidence puts them in the "needs review" view of `99-assistant/assistant.base`.
  - Todos, calendar entries, and appends to existing notes: tagged `#assistant/review`.
- Items for which the AI returned no action go to review.

### 4.3 Calendar
- v1 doesn't add events to a calendar directly.
- Calendar candidates are collected in `99-assistant/calendar-queue.md` in a set format.
- Adding them through ego-lite (or macOS Calendar/EventKit) is v2 scope.

## 5. Learning rules
- Rule files live in `99-assistant/rules/`: `todo-format.md`, `placement.md`, `calendar-format.md`
- Each file holds rules plus good and bad examples, and is included in the AI prompt on every run.
- Cases where the user corrected a result accumulate as examples to improve accuracy.

## 6. Safety and privacy

### 6.1 Write constraints
- **No deleting.** No modifying existing content.
- The only exception: **moving** processed blocks from the inbox (`active.md`) to the archive (following rules C and D in 3.2).
- Every operation is logged in `99-assistant/log/YYYY-MM-DD.md` (what, where, from which original).

### 6.2 Read scope
- The AI can't access vault files (section 8). The prompt contains only the blocks, summaries of related notes picked by index search (up to 8 per block), the folder structure, and the rules.
- Excluded by default: `.obsidian`, `.trash`, `.git`, `excalidraw`, `assets`.
- Paths in `99-assistant/.assistantignore` are left out of the index and the folder structure, so **the code** keeps them from ever reaching the AI.

### 6.3 Initial mode
- For roughly the first week, Sift runs in **dry-run**: it writes nothing and only records the planned work as proposals in `99-assistant/review/dry-run-YYYY-MM-DD.md`.
- After reviewing them, the user turns on real writing in settings.

## 7. Assistant folder layout
```
99-assistant/
├── todo.md
├── calendar-queue.md
├── assistant.base          # view of low-confidence items and notes the assistant created
├── inbox-archive/YYYY-MM.md
├── backup/
├── review/
├── rules/
│   ├── todo-format.md
│   ├── placement.md
│   ├── calendar-format.md
│   └── frontmatter.md
├── log/YYYY-MM-DD.md
└── .assistantignore
```
Processing state (hashes, recent history) is stored outside the vault, in `~/Library/Application Support/Sift/`.

## 8. How the AI is called
- `codex exec` runs in an empty temporary folder **with the shell tool turned off** (`--disable shell_tool`, plus the app and browser features). The AI can't read or write files.
- What it knows about the vault comes from the local index (`~/Library/Application Support/Sift/index.json`).
  - Per note: path, title, some frontmatter, headings, and the first 300 characters. Updated incrementally by modification time.
  - Search: character bigrams + a bonus for matching words in the path/title + a weight for recent edits. No external services.
- The AI returns only a JSON plan (`--output-schema`); the core code does the actual writing.
- Measured (2026-09-26, 2 blocks): about 45 seconds when the AI explored the vault directly → 15–17 seconds with the index.
- Safety rules (no deleting, create/append only, reject paths outside the vault, hidden folders, the inbox, and the assistant folder) are enforced in code.
  Actions that break them aren't dropped but sent to review. Blocks missing from the plan also go to review.

## 9. Menu bar app
- A SwiftUI `MenuBarExtra` app separate from the core. It reads `status.json` and gives commands by editing `config.json` and dropping request files (run now, quick notes) in the support folder.
- Shows: a status icon (idle / waiting while you write / processing / error / paused), a dry-run indicator, the number of inbox blocks, the last check time, today's stats, and the 10 most recent items (clicking one opens it in the macOS default app or the app chosen in settings)
- Controls: Process now (skips both the 5-minute wait and the last-block hold and processes immediately; rule C, which discards the result if the inbox changes during analysis, still applies), pause/resume, dry-run toggle, and opening the inbox, todo, calendar, review, and log

## 10. Out of scope (v2 and later)
- Adding events to Google Calendar directly through ego-lite
- Claude engine support
- Git versioning of the vault
- Messenger notifications, Daily Note integration
