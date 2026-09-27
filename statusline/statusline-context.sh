#!/usr/bin/env bash
# Context-window status line for Claude Code.
# Renders: "<model> · <pct>% ctx (<used>k/<window>k)" and recolors green->yellow->red.
#
# Claude Code pipes session JSON to this script on stdin; whatever it prints
# becomes the bottom status line. Requires `jq`.
#
# Optional env overrides (export before launching Claude Code):
#   CLAUDE_CTX_WINDOW   force the window size in tokens (e.g. 200000 or 1000000)

input=$(cat)

# Never break the status line if jq is missing — degrade to just a label.
if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude (install jq for ctx%%)'
  exit 0
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
model_name=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')
model_id=$(printf '%s' "$input" | jq -r '.model.id // empty')

# Context window: explicit override wins; otherwise infer 1M vs the standard 200k.
if [[ -n "${CLAUDE_CTX_WINDOW:-}" ]]; then
  window="$CLAUDE_CTX_WINDOW"
else
  case "$model_id" in
    *1m*|*"[1m]"*) window=1000000 ;;
    *)             window=200000  ;;
  esac
fi

# Current context size = the most recent turn's cumulative input tokens
# (fresh input + cache read + cache creation) — the same accounting Claude Code uses.
used=0
if [[ -f "$transcript" ]]; then
  used=$(jq -rs '
    [ .[]
      | select(.message.usage != null)
      | .message.usage
      | (.input_tokens // 0)
        + (.cache_read_input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
    ] | last // 0' "$transcript" 2>/dev/null)
fi
used=${used:-0}
[[ "$used" =~ ^[0-9]+$ ]] || used=0

pct=$(( used * 100 / window ))

if   (( pct < 60 )); then color=$'\e[32m'   # green
elif (( pct < 80 )); then color=$'\e[33m'   # yellow
else                      color=$'\e[31m'   # red
fi
reset=$'\e[0m'

printf '%s · %s%d%% ctx%s (%dk/%dk)' \
  "$model_name" "$color" "$pct" "$reset" $(( used / 1000 )) $(( window / 1000 ))
