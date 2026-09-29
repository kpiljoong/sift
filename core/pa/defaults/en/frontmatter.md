# Frontmatter rules

The program writes the frontmatter of new notes. The AI only picks the values below (properties).

## type
- The kind of note. Lowercase English; more than one is allowed.
- Common values: idea, meeting, project-note, decision, reference, log, plan, question
- Specific values like `assignment`, `quiz`, or `cloud-service-design`, as in the existing vault, are fine too.

## project
- The same name as a folder under 01-projects (e.g. beta, alpha). null if there is none.

## tags
- Only when really needed. Lowercase, `-` instead of spaces, `/` for hierarchy (e.g. `travel/japan`).

## Values the program adds automatically
- date: the date it was processed
- source: assistant
- confidence: the AI's confidence (0–1). Below the threshold, the note shows up in the "Needs review" view of `99-assistant/assistant.base`.
- For meetings, categories: "[[Meetings]]" (works with Meetings.base)
