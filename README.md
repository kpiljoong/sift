# Sift

> A macOS menu bar assistant that sifts a free-form markdown inbox into todos, notes, and calendar candidates using the Codex CLI. Works with any folder of markdown notes (an Obsidian vault included).

Jot anything into the inbox file of your markdown notes folder (the vault; default `00-inbox/active.md`), or drop it in with the ⌥Space quick note.
Codex reads it in the background and files it into the vault as todos, notes, and calendar candidates. See [REQUIREMENTS.md](REQUIREMENTS.md) for the requirements.

- The AI never touches files. It only returns a plan (JSON); the code does the writing, and only by **creating new files or appending to the end**. Nothing is deleted.
- Processed text is kept verbatim in `99-assistant/inbox-archive/`, and every result links back to its original.

> The app is in English or Korean. A first install asks which; change it later under **Language** in settings.
> The same setting decides the language of what Sift writes into the vault (headings, logs, default rules). Existing files are never rewritten.

## Install
**Requirements**
- macOS 13 or later (Apple Silicon and Intel)
- [Codex CLI](https://github.com/openai/codex), logged in (`codex login`). The default path is `/opt/homebrew/bin/codex`; you can change it in settings.
- Xcode Command Line Tools: the core runs on `/usr/bin/python3`. If they're missing, the menu bar shows an **Install…** button.
- If Codex is missing or not logged in, the menu bar explains what to do and offers a **Log In…** button.

**From a release**
1. Download `Sift-<version>.zip` from [Releases](../../releases/latest), unzip it, and open `Sift.app`.
   - The app isn't signed or notarized, so macOS blocks it the first time. Click **Open Anyway** near the bottom of
     **System Settings > Privacy & Security** (on macOS 14 and earlier, right-click the app > Open).
2. When asked whether to move it to the Applications folder, choose **Move**. Sift moves itself to `~/Applications/Sift.app`, relaunches,
   installs the core, and sets itself up to start at login.
   - If you prefer the terminal, run `./scripts/install.sh` from the unzipped folder instead. It does the same and also clears the quarantine flag, so step 1's approval isn't needed.
3. Use **Choose…** in the menu bar to pick your notes folder (vault), then pick an inbox file inside it or create a new one. An Obsidian vault works as is.
   - If the vault is in Documents, Desktop, or iCloud Drive, macOS asks whether Sift may access it. Allow it, or Sift can't sort anything.
   - Results collect in the vault's `99-assistant/` folder.

**Updates:** Sift checks once a day and shows a bubble when a new version is out (turn this off or check now under **Updates** in settings).
- Updates are installed only after their Ed25519 signature checks out. Updates that only change the sorting engine (core) apply right away without a relaunch;
  updates that change the app replace it and relaunch (macOS may ask for folder access again).
- A check only asks GitHub for the latest version info and sends nothing else.

**From source:** clone the repository and run `./scripts/install.sh`. It builds and installs the menu bar app.

To uninstall, run `./scripts/uninstall.sh` (settings, processing history, and the vault are kept).

## Layout
| Path | Contents |
|---|---|
| `core/pa/` | Sorting engine (Python 3.9 standard library only) |
| `core/pa/defaults/` | Rule files copied into the vault on first setup (`en/`, `ko/`) |
| `core/tests/` | Tests against a fake vault and a fake engine |
| `menubar/` | SwiftUI menu bar app and `build.sh` |
| `scripts/install.sh` | Install / update (safe to re-run) |
| `scripts/uninstall.sh` | Removes the launchd job and the app (keeps the vault and settings) |
| `scripts/package.sh` | Builds the release zip |

Once installed, Sift uses:
- `~/Library/Application Support/Sift/`: `config.json`, `state.json`, `status.json`, `logs/core.log`, and the installed core (`app/`)
- `~/Library/LaunchAgents/io.github.kpiljoong.sift.menubar.plist`: starts the app at login. The app runs the core every minute.
- `~/Applications/Sift.app`
- In the vault: `99-assistant/` (todo, calendar candidates, archive, backup, review, rules, log)

## Usage
1. Write freely in `active.md`. Each chunk separated by a blank line is one block.
2. Processing starts once the file has been left alone for 5 minutes. The last block waits until it hasn't changed for 10 minutes. (Defaults; change them in settings.)
3. Processed blocks move to `99-assistant/inbox-archive/`, and each result ends with a link to its original.
4. If you don't like the results, add rules and examples to `99-assistant/rules/*.md`. They apply from the next run.
5. Items the AI wasn't sure about are gathered in `99-assistant/assistant.base` (a needs-review view) and under the `#assistant/review` tag.
6. If something was filed wrong, hover over it under **Recent** in the menu bar and click ↺ (or right-click > **Re-sort…**), then say how to change it.
   Sift re-sorts the original as instructed and records the correction in `99-assistant/rules/corrections.md`, so later runs follow it.
   The earlier entry is not deleted; remove it yourself if needed.

### Quick note (⌥Space by default)
Open the quick note from anywhere with ⌥Space, write as many lines as you like, and press ⌘⏎ to add it to the inbox. Quick notes are sorted right away, with no waiting or holding.
- To change the shortcut, go to **Shortcuts** in settings, click **Change**, and press the new combination (it must include ⌘, ⌥, or ⌃; Esc cancels). **Default** restores ⌥Space.
  Combinations apps commonly use (like ⌘V) and macOS shortcuts are refused, and the previous key stays. If pressing a combination does nothing, another app is using it; pick a different one.
- **Point at a destination with `@`:** type `@` to get a list of the vault's notes and folders that narrows as you type (↑↓, ⏎; Esc closes it).
  Typing `/`, as in `@01-projects/`, lists everything inside that folder; ⇥ on a folder opens it. A chosen target shows up short, like `@alpha/`,
  and goes into the inbox as an exact path, like `@[[01-projects/alpha/]]`. Point at a note and the memo goes into that note; point at a folder and it's filed inside that folder.
  You can also write `@file-name` (or `@folder-name/` for a folder) directly in the inbox. The list comes from the core's index, so `.assistantignore` paths never appear.
- Esc or clicking elsewhere closes it; what you were writing stays as a draft, and reopening puts the caret back where you left off.
- Text size: the −/+ buttons at the bottom, ⌘+ / ⌘- / ⌘0, or a trackpad pinch. Window opacity (40–100%): the ◐ menu at the top, or ⌘[ / ⌘]. Both are remembered.
- Anything you write in the **Ask the AI** field becomes a `Request: …` line (`요청: …` in Korean) in front of the memo, and the whole memo is sorted as one, following that instruction
  (e.g. "turn this into meeting notes", "add to the alpha note"). Writing a `Request:` or `요청:` line directly in the inbox works the same way.
- With the **Meeting** toggle on, the window stays open and only saves a draft. ⌘⏎ (end meeting) adds it as one memo under a `## Meeting notes (start–end)` header.
  While a meeting is on, the window reopens where you last moved or resized it (pulled back on screen if that spot is off screen or on a disconnected display); the next meeting starts in the usual place.
- The menu bar app drops the memo into `~/Library/Application Support/Sift/quick/`, and the core appends it to the inbox.

Change the check interval, the wait after writing, the last-block hold, the needs-review threshold, and the vault, inbox, and codex locations in the menu bar's **Settings…** window.
Clicking a recent item, a bubble, or a shortcut opens the note in macOS's default app; under **Opening** you can pick another app such as [Margin](https://github.com/kpiljoong/margin).
Changes are saved immediately and apply from the next check. The inbox must be a `.md` file inside the vault
(not inside `99-assistant/`), and Sift never creates an inbox on its own. Switching vaults starts the recent history over.

**Sift starts in dry-run mode.** It doesn't write anything and only leaves proposals in `99-assistant/review/dry-run-<date>.md`.
When the proposals look right, turn dry-run off in the menu bar. Blocks proposed during dry-run are processed for real after you turn it off.

## CLI
```sh
cd ~/Library/Application\ Support/Sift/app
python3 -m pa status               # current status
python3 -m pa run --force          # process everything now, including the last block (same as the menu bar's Process Now)
python3 -m pa set dry_run false    # change a setting (quiet_minutes, language, ...)
```

## Development
```sh
cd core && python3 -m unittest discover -s tests   # tests
./scripts/install.sh                                # reinstall after changing code
./scripts/package.sh                                # release zip (dist/)
```
Releasing: bump `VERSION` and push a `v<version>` tag. GitHub Actions runs the tests, builds a universal binary, and uploads the Release.
The in-app update files (`sift-update.json`/`.sig`, `sift-core-*.zip`, `sift-app-*.zip`) are signed with the repository secret `SIFT_UPDATE_KEY`
(a key made with `swift scripts/update-sign.swift keygen`; the public key is `updatePublicKey` in `menubar/Sift.swift`).
The app is replaced only by releases that change `Sift.swift` or `build.sh`; all others replace just the core.
