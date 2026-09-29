# Todo format rules

The assistant reads these rules on every run. Change them freely and add examples.

## Format (compatible with Obsidian Tasks)
- One per line: `- [ ] <task starting with a verb> [📅 YYYY-MM-DD] [#tags...]`
- Add `📅` only when a deadline or date is mentioned. Turn "tomorrow", "next Friday", etc. into actual dates.
- Add `⏫` if the priority is clearly high, `🔽` if clearly low. If unclear, add neither.
- If there's a related project, add a `#project/<folder name>` tag.
- Don't write a link to the original; the engine adds it automatically.

## Good examples
- [ ] Call the dentist to book an appointment 📅 2026-09-27
- [ ] Draft the metric definitions for the alpha dashboard #project/alpha

## Bad examples
- [ ] dentist (unclear what to do)
- [ ] call dentist tomorrow (relative date left as is)
