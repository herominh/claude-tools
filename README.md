# claude-tools

Personal, machine-wide Claude Code tooling — installed into
`${CLAUDE_CONFIG_DIR:-~/.claude}`, active in every project on the machine.

| Tool | What it does |
|---|---|
| `keep-warm/` | Keeps an idle session's prompt cache warm with a few cheap pings, so coming back after a break does not re-write the whole context at the cache-write rate |
| `statusline/` | Status line showing how full the session's context window is |
| `handoff/` | `/handoff` skill: writes `HANDOFF.md` before a break, so the next session starts fresh from a short note instead of re-reading a cold context |

Each tool stands alone — install any one without the others. They only need
bash, `jq` (keep-warm, statusline) and Claude Code; no other service, account
or repository. The one cross-tool touch is optional: keep-warm skips its pings
when the session's last action wrote `HANDOFF.md`, whatever wrote it.

Requirements: bash (macOS's stock 3.2 is fine), `jq`, Claude Code 2.1.281 or
newer for keep-warm.

> **Heads-up:** keep-warm relies on Claude Code hook behaviour that is not
> formally documented (async `Stop` hooks that re-wake the session, prompt-cache
> lifetimes). It has changed between Claude Code releases before; after an
> upgrade, check that pings still arrive and cost what you expect.

## keep-warm

```bash
bash keep-warm/install.sh install     # copy the hook + /m-keep-warm skill, register 6 hooks
bash keep-warm/install.sh uninstall   # remove the registrations and both copies
```

Install writes `hooks/keep-warm.sh`, `skills/m-keep-warm/SKILL.md` and, in
`settings.json`, the handlers from `keep-warm/registrations.json`, each running
`bash "<config dir>/hooks/keep-warm.sh" --machine-wide`. Every other setting
stays; the file as it was before the first install is kept as
`settings.json.keep-warm-backup`. It refuses, changing nothing, without `jq`,
on a Claude Code below the hook's `MIN_CLAUDE_VERSION`, or when `settings.json`
is not a JSON object or is a symlink (then add the six entries by hand).

- **Every Claude Code on the machine must meet the minimum version:** only the
  `claude` on PATH is checked, but an IDE extension's bundled copy or a second
  install reads the same `settings.json`, and an older one skips the whole
  file — deny rules included.
- **No double pings:** a project that registers its own keep-warm hook in its
  `.claude/settings.json` (or `settings.local.json`) keeps using its own copy;
  the machine-wide one stands down there.
- **Controls:** `/m-keep-warm <0-10|off>` in a session; for a machine-wide count
  put `CLAUDE_KEEP_WARM_PINGS` under `"env"` in `~/.claude/settings.json`.
- **After changing the hook:** re-run `install`.
- **Cost:** every idle session sends up to 3 pings — close sessions you are
  done with.

`registrations.json` holds the hook block as a project would register it; the
installer keeps each handler's fields and replaces only the command.

Tests (macOS bash 3.2 and Linux):

```bash
bash keep-warm/tests/keep-warm.test.sh
bash keep-warm/tests/install.test.sh
```

## statusline

`statusline/statusline-context.sh` is the source of `~/.claude/statusline-context.sh`.
Install by copying it there and registering it in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "CLAUDE_CTX_WINDOW=1000000 bash \"/Users/<you>/.claude/statusline-context.sh\"",
  "padding": 0
}
```

`CLAUDE_CTX_WINDOW` is the model's context window in tokens.

## handoff

```bash
mkdir -p ~/.claude/skills/handoff && cp handoff/SKILL.md ~/.claude/skills/handoff/
```

Make `/handoff` your last prompt before a break (`/handoff <task>` does the task
first, then writes the note). Next time, start a NEW session and type
`Read HANDOFF.md and continue.` — cheaper than resuming an old session whose
cache has expired. The note lands in the project root; keep it out of git
(add `HANDOFF.md` to `.gitignore`). Works in any directory, git repository or not.

## License

MIT — see `LICENSE`.
