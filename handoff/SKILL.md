---
name: handoff
description: Write a handoff note (HANDOFF.md at the project root) the moment the current work stops, so the NEXT Claude Code session starts fresh from the note instead of resuming a cold context after a break longer than the prompt-cache lifetime. Use as the developer's LAST prompt before a break — `/handoff <task>` runs the task first, then writes the note; bare `/handoff` writes the note for the work already done (typed while a task is running it queues and fires when that task ends). Never invoke on your own judgment. Accidental use is harmless — the next run overwrites the file. The note is in the developer's language unless the arguments name another.
argument-hint: [language] [task]
---

# /handoff — handoff note for the next session

Announce, own line: `handoff: armed (<language>) — HANDOFF.md will be written when the work stops`
(append ` — N subagent(s) / background task(s) still running, waiting for them`
when anything is in flight, so the wait is visibly deliberate).

Language of the note — the language the developer writes to you in this
session by default, another language on request:
- A language named in the arguments in plain words, no strict syntax
  (`/handoff english`, `/handoff in Vietnamese <task>`) → write the note in that
  language. The language words are not part of the task — what remains after
  them is the task, and nothing remaining means a bare invocation.
- Only a request about the NOTE counts. A language named inside the task text is
  part of the task: `/handoff fix the English labels on the form` → default language.
- Unclear → English. NEVER ask which language: this is the last prompt before a
  break (and one typed mid-task fires when the task ends), so a question would
  block the note from being written at all.
- Both announce lines name the language, so a misread shows before the
  developer leaves.

1. Arguments given → do that task first, exactly as you would without this skill.
2. The moment the work stops — finished, blocked, or waiting on a decision
   only the developer can make — write `HANDOFF.md` in the project root: the
   directory Claude Code was started in (`$CLAUDE_PROJECT_DIR`). Overwrite any
   previous note. Use the template below, translated into the chosen language
   (headings, labels and values, same section order). Facts only, taken from
   this session plus `git status` / `git log` when the project is a git
   repository — never reconstruct from memory what you did not verify.
3. Print `handoff: written (<language>) — HANDOFF.md (<branch> @ <short sha>)`
   (or `(not a git repository)`), then the normal final report.

Rules:
- The note is a local scratch file, never committed. In a git repository where
  `git check-ignore -q HANDOFF.md` fails, say in the final report that the file
  is not ignored yet — do not edit `.gitignore` yourself.
- In-flight work is not "stopped". If subagents, background tasks or a
  detached run are still going when this skill fires, do NOT write the note
  yet: end the turn, let their notifications arrive, finish the task with their
  results, and write HANDOFF.md only after the last one returns. A note written
  mid-flight goes stale the moment the results land, and nothing rewrites it.
  The developer can force an immediate note with `/handoff write now`.
- Checkpoint before a long wait. When the wait you are about to enter can
  plausibly run near or past the cache lifetime (a full test-suite run, a
  multi-agent job), write HANDOFF.md FIRST as a checkpoint — "In progress"
  names what is running and where its output lands (log path, results file) —
  then wait, then overwrite it with the final note when the work returns.
- Write the note BEFORE the final report, so a context limit can never eat it.
- "In progress" names the exact half-edited files and the exact failing tests;
  "Next steps" must be executable by a session that has read nothing but this
  note and the project.
- Every open question or pending decision in the note explains itself: what
  the thing is, how it got here, what happens under each option — a concrete
  example when there is one — and what each option costs. Never a bare name,
  ticket number or shorthand the reader must decode.
- "Resume the old session" = yes ONLY when in-flight state cannot be rebuilt
  from the note plus the project (e.g. halfway through a subtle debugging
  chain) — the developer then resumes the old session and pays the cache
  rebuild deliberately. Default no.
- Never write secrets, credentials, or personal data into the note.
- Return side: the developer's first prompt in the new session is
  `Read HANDOFF.md and continue.` — read the note only on that request, never
  on your own: a fresh session for a different task must start clean.

Template:

```markdown
# Session handoff

- Time: <YYYY-MM-DD HH:MM>
- Branch: <branch> @ <short sha> — <clean | N uncommitted files>   (or: not a git repository)
- Resume the old session: <no | yes — reason>

## Done
- ...

## In progress
- ... (which files are half-edited, which tests are failing)

## Next steps
1. ...

## Key decisions (with reasons)
- ...
```
