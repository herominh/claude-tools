---
name: m-keep-warm
description: Set how many keep-warm pings THIS session sends while you are away — `/m-keep-warm <0-10>`, `/m-keep-warm off`, or bare `/m-keep-warm` to show the current setting. The pings themselves are automatic (the keep-warm hook — the project's scripts/claude/keep-warm.sh, else its machine-wide copy in the Claude config dir); this only changes the count. User-invoked only.
argument-hint: "[0-10 | off]"
disable-model-invocation: true
---

# /m-keep-warm — keep-warm pings for this session

Run exactly one command, then relay its single output line verbatim and stop —
no other tool call, no other work. Each command uses the project's copy of the
hook when it has one, else the machine-wide copy:

- Arguments given (`$ARGUMENTS`):
  `hook="${CLAUDE_PROJECT_DIR}/scripts/claude/keep-warm.sh"; [ -f "$hook" ] || hook="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/keep-warm.sh"; bash "$hook" set "${CLAUDE_SESSION_ID}" "$ARGUMENTS"`
  (the value stays inside the double quotes as one argument; the script
  validates it)
- No arguments:
  `hook="${CLAUDE_PROJECT_DIR}/scripts/claude/keep-warm.sh"; [ -f "$hook" ] || hook="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/keep-warm.sh"; bash "$hook" status "${CLAUDE_SESSION_ID}"`

If the command rejects the value (exit 1), relay its message and add one line:
`Usage: /m-keep-warm <0-10> | off` — never guess a value for the developer.

What the setting controls is documented in the claude-tools README
("keep-warm"): by default the first ping 50 minutes
after the last turn, then one every 55 minutes, each costing 1/20 or less of
the cache rebuild it prevents.
