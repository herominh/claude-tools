#!/usr/bin/env bash
#
# Claude Code hook — keeps an IDLE session's prompt cache warm with a few short
# pings, so a developer back from lunch resumes at the cache-read price instead
# of re-writing the whole context (a 1-hour cache write costs 2x the input
# price, a read at most 0.1x — one ping is 1/20 of a rebuild or less).
#
# Registered in .claude/settings.json on six events; dispatches on
# hook_event_name:
#   Stop             arm a wait (async + asyncRewake: runs in the background,
#                    exit 2 wakes the session with the ping text on stderr).
#                    First ping DEFAULT_FIRST_WAIT_SECONDS after the turn ends,
#                    later ones DEFAULT_NEXT_WAIT_SECONDS after the previous
#                    ping turn. Up to N pings.
#   UserPromptSubmit the developer is back: cancel the wait, reset the count.
#                    Claude Code also delivers each ping here (observed
#                    2026-09-27, 2.1.283) — that echo must not reset the count.
#   PreToolUse       (matcher Agent|Task) a main-session subagent spawn is
#                    activity now — its PostToolUse only arrives at the end.
#   PostToolUse      a main-session tool call is activity that cancels an
#                    armed wait (a subagent's is ignored — its requests never
#                    refresh the main session's cache); also tracks "the last
#                    main-session tool call wrote HANDOFF.md" — /m-handoff was
#                    the developer's last prompt, they will start fresh.
#   StopFailure      a turn ended in an API error after Claude Code's own
#                    retries: stop the chain — the cache may already be gone,
#                    and a ping would then pay the full rebuild while nobody
#                    is there.
#   SessionEnd       cancel the wait.
#
# --machine-wide marks the copy keep-warm-install.sh registers in the user
# settings for every project: it does nothing where the project's own settings
# register keep-warm.sh too, so a session never runs two hooks racing on one
# state.
#
# Also a CLI for /m-keep-warm:  keep-warm.sh set <session_id> <0-10|off>
#                               keep-warm.sh status <session_id>
#
# Count: `set` override for the session, else CLAUDE_KEEP_WARM_PINGS, else
# DEFAULT_PINGS. Timing overrides, for the fixture test and a live
# short-interval check (seconds): CLAUDE_KEEP_WARM_FIRST_SECONDS,
# CLAUDE_KEEP_WARM_NEXT_SECONDS, CLAUDE_KEEP_WARM_POLL_SECONDS,
# CLAUDE_KEEP_WARM_LATE_GRACE_SECONDS, CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS; a wait of CACHE_TTL_SECONDS or more
# falls back to the default — it would outlive the cache and the Stop hook's
# `timeout` (3600 s in settings.json). State lives in
# ${CLAUDE_KEEP_WARM_STATE_DIR:-$TMPDIR}/claude-keep-warm-<session>/.
#
# A wait exits 0 silently when superseded — a newer `gen` (another turn ended,
# a prompt, StopFailure, SessionEnd), main-session activity stamped after the
# wait started (a prompt or tool call, whatever order the hooks ran in), or Claude Code
# itself gone (CLAUDE_PID). It fails CLOSED: state it cannot write means no
# ping, since nothing could then cancel the wait or end the chain.
#
# Guards — the hook does nothing when:
#   - `claude --version` reads below MIN_CLAUDE_VERSION or cannot be read (an
#     older Claude Code that ignored `async` would run the wait in the
#     foreground and freeze the session);
#   - the environment says the session runs on the 5-minute cache (only
#     subscribers get the 1-hour one by default — there a ping would pay a full
#     rebuild, not a read);
#   - a wait resumes more than the late grace past its deadline (the Mac slept;
#     the cache has presumably expired) — that also stops the chain.
#
# Exit codes: 0 always, except 2 = the ping (Stop only) and 1 = a rejected
# `set` / `status`. Fixture tests: bash keep-warm/tests/keep-warm.test.sh

set -u

readonly PING_MARKER='[keep-warm ping]'
readonly DEFAULT_PINGS=3
readonly MAX_PINGS=10
readonly MIN_CLAUDE_VERSION='2.1.281'
# Anthropic's 1-hour prompt cache, counted from the START of the last request.
readonly CACHE_TTL_SECONDS=3600
# 50 min: the timer starts when the turn ENDS, after the final reply was
# generated — 10 min of margin covers a long final reply.
readonly DEFAULT_FIRST_WAIT_SECONDS=3000
# 55 min: a ping turn is a one-word reply, so 5 min of margin is enough.
readonly DEFAULT_NEXT_WAIT_SECONDS=3300
readonly DEFAULT_POLL_SECONDS=30
# How late a ping may still fire: a normal wait overshoots by under a second;
# 2 min keeps even a 55-min wait inside the cache hour.
readonly DEFAULT_LATE_GRACE_SECONDS=120
# A prompt this soon after our own ping is the ping delivered back to us.
readonly DEFAULT_PING_ECHO_WINDOW_SECONDS=60
readonly SECONDS_PER_MINUTE=60
readonly SECONDS_PER_HOUR=3600

state_base="${CLAUDE_KEEP_WARM_STATE_DIR:-${TMPDIR:-/tmp}}"

# $1 = a string of digits: the number in base 10 (bash arithmetic would read a
# leading zero as octal).
to_int() {
    printf '%s' "$((10#$1))"
}

# $1 = override, $2 = default: the override when it is a positive whole number
# of seconds below $3, else the default.
seconds_or() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$2"; return ;;
    esac
    local value
    value=$(to_int "$1")
    if [ "$value" -gt 0 ] && [ "$value" -lt "$3" ]; then printf '%s' "$value"; else printf '%s' "$2"; fi
}

first_wait=$(seconds_or "${CLAUDE_KEEP_WARM_FIRST_SECONDS:-}" "$DEFAULT_FIRST_WAIT_SECONDS" "$CACHE_TTL_SECONDS")
next_wait=$(seconds_or "${CLAUDE_KEEP_WARM_NEXT_SECONDS:-}" "$DEFAULT_NEXT_WAIT_SECONDS" "$CACHE_TTL_SECONDS")
poll_seconds=$(seconds_or "${CLAUDE_KEEP_WARM_POLL_SECONDS:-}" "$DEFAULT_POLL_SECONDS" "$CACHE_TTL_SECONDS")
late_grace=$(seconds_or "${CLAUDE_KEEP_WARM_LATE_GRACE_SECONDS:-}" "$DEFAULT_LATE_GRACE_SECONDS" "$CACHE_TTL_SECONDS")
echo_window=$(seconds_or "${CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS:-}" "$DEFAULT_PING_ECHO_WINDOW_SECONDS" "$CACHE_TTL_SECONDS")

# "50 min", "3h40m", "30s".
format_duration() {
    local seconds="$1"
    if [ "$seconds" -lt "$SECONDS_PER_MINUTE" ]; then
        printf '%ss' "$seconds"
    elif [ "$seconds" -lt "$SECONDS_PER_HOUR" ]; then
        printf '%s min' "$(( seconds / SECONDS_PER_MINUTE ))"
    else
        printf '%dh%02dm' "$(( seconds / SECONDS_PER_HOUR ))" "$(( seconds % SECONDS_PER_HOUR / SECONDS_PER_MINUTE ))"
    fi
}

# True when $1 is a count this script accepts (0..MAX_PINGS).
valid_count() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(to_int "$1")" -le "$MAX_PINGS" ]
}

# Session ids become directory names: allow only a conservative charset.
valid_session() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

state_dir_for() {
    printf '%s/claude-keep-warm-%s' "$state_base" "$1"
}

# read_state <file> <default>
read_state() {
    local value
    value=$(cat "$dir/$1" 2>/dev/null) || value=''
    [ -n "$value" ] || value="$2"
    printf '%s' "$value"
}

# write_state <file> <value> — write-then-rename so a reader never sees half;
# returns non-zero when the value did not land.
write_state() {
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s' "$2" > "$dir/$1.$$" 2>/dev/null || return 1
    mv -f "$dir/$1.$$" "$dir/$1" 2>/dev/null || return 1
    [ "$(read_state "$1" '')" = "$2" ]
}

# Bumping gen supersedes every armed wait of the session.
bump_gen() {
    write_state gen "$(( $(read_state gen 0) + 1 ))"
}

stamp_activity() {
    write_state activity_at "$(date +%s)"
}

ping_limit() {
    local limit
    limit=$(read_state max '')
    if valid_count "$limit"; then to_int "$limit"; return; fi
    limit="${CLAUDE_KEEP_WARM_PINGS:-}"
    if valid_count "$limit"; then to_int "$limit"; return; fi
    printf '%s' "$DEFAULT_PINGS"
}

# True when $1 is a truthy switch value the way Claude Code parses one
# (1 / true / yes / on, any case); "0", "false" and empty count as unset.
truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        1|true|yes|on) return 0 ;;
    esac
    return 1
}

# True unless the environment puts this session on the 5-minute cache, decided
# in Claude Code's own order (2.1.283 — it changed since 2.1.281, so re-check
# on upgrades): a forced 5 min; the TTL variable ("5m" / "1h"); the 1-hour
# switches; then a non-subscriber (API key, auth token, a cloud provider) gets
# 5 min and a subscriber 1 h. A subscriber login leaves no trace in the
# environment. Invisible here: the `promptCacheTtl` setting, an apiKeyHelper,
# usage overage — the README tells those developers to switch the pings off.
on_one_hour_cache() {
    truthy "${FORCE_PROMPT_CACHING_5M:-}" && return 1
    case "$(printf '%s' "${CLAUDE_CODE_PROMPT_CACHE_TTL:-}" | tr -d '[:space:]')" in
        1h) return 0 ;;
        5m) return 1 ;;
    esac
    truthy "${ENABLE_PROMPT_CACHING_1H:-}" && return 0
    truthy "${CLAUDE_CODE_USE_BEDROCK:-}" && truthy "${ENABLE_PROMPT_CACHING_1H_BEDROCK:-}" && return 0
    local provider
    for provider in "${CLAUDE_CODE_USE_BEDROCK:-}" "${CLAUDE_CODE_USE_VERTEX:-}" "${CLAUDE_CODE_USE_FOUNDRY:-}" \
        "${CLAUDE_CODE_USE_ANTHROPIC_AWS:-}" "${CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD:-}" "${CLAUDE_CODE_USE_MANTLE:-}"; do
        truthy "$provider" && return 1
    done
    [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] && return 1
    return 0
}

# True when `claude --version` is at least MIN_CLAUDE_VERSION. Checked once
# per session; an unreadable version counts as too old.
claude_version_ok() {
    local cached found
    cached=$(read_state version_ok '')
    [ -n "$cached" ] && { [ "$cached" = yes ]; return; }
    found=$(claude --version 2>/dev/null | head -n 1 | grep -o -E '^[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$found" ] && version_at_least "$found" "$MIN_CLAUDE_VERSION"; then
        write_state version_ok yes
        return 0
    fi
    write_state version_ok no
    return 1
}

# version_at_least <x.y.z> <x.y.z>
version_at_least() {
    local IFS=.
    local -a have want
    read -r -a have <<< "$1"
    read -r -a want <<< "$2"
    local i
    for i in 0 1 2; do
        [ "${have[$i]}" -gt "${want[$i]}" ] && return 0
        [ "${have[$i]}" -lt "${want[$i]}" ] && return 1
    done
    return 0
}

# First top-level-looking "key":"string" value in the JSON on $input. Enough
# for the fixed-shape ids and event names; tool input goes through jq.
json_field() {
    local pattern="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    [[ "$input" =~ $pattern ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# True when the event comes from inside a subagent: Claude Code sets a
# TOP-LEVEL agent_id only then. json_field finds the first "agent_id" anywhere,
# so a hit is confirmed with jq — a tool response may carry its own agent_id.
from_subagent() {
    [ -n "$(json_field agent_id)" ] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    [ -n "$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)" ]
}

# True when the project's settings register keep-warm.sh themselves: a
# "command" line naming it without --machine-wide. A session started in the home
# directory reads the user settings as its project settings, and there the only
# registration is the machine-wide one (whose rewakeMessage names the script too).
project_registers_own_hook() {
    [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
    local settings
    for settings in "$CLAUDE_PROJECT_DIR/.claude/settings.json" "$CLAUDE_PROJECT_DIR/.claude/settings.local.json"; do
        [ -f "$settings" ] || continue
        grep -F 'keep-warm.sh' "$settings" 2>/dev/null | grep -F '"command"' | grep -F -v -q -e '--machine-wide' && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# CLI: keep-warm.sh set <session_id> <0-10|off>

if [ "${1:-}" = "set" ]; then
    session="${2:-}"
    requested="${3:-}"
    if ! valid_session "$session"; then
        printf 'keep-warm: unusable session id "%s"\n' "$session" >&2
        exit 1
    fi
    [ "$requested" = "off" ] && requested=0
    if ! valid_count "$requested"; then
        printf 'keep-warm: the count must be a whole number from 0 to %s, or "off" (got "%s")\n' "$MAX_PINGS" "${3:-}" >&2
        exit 1
    fi
    requested=$(to_int "$requested")
    dir=$(state_dir_for "$session")
    if ! write_state max "$requested"; then
        printf 'keep-warm: could not save the setting under %s\n' "$dir" >&2
        exit 1
    fi
    if [ "$requested" -eq 0 ]; then
        printf 'keep-warm: off for this session\n'
    else
        warm_for=$(( first_wait + next_wait * (requested - 1) + CACHE_TTL_SECONDS ))
        printf 'keep-warm: up to %s ping(s) for this session — the first %s after the last turn, then every %s; the cache stays warm about %s after you leave\n' \
            "$requested" "$(format_duration "$first_wait")" "$(format_duration "$next_wait")" "$(format_duration "$warm_for")"
    fi
    exit 0
fi

# CLI: keep-warm.sh status <session_id>

if [ "${1:-}" = "status" ]; then
    session="${2:-}"
    if ! valid_session "$session"; then
        printf 'keep-warm: unusable session id "%s"\n' "$session" >&2
        exit 1
    fi
    dir=$(state_dir_for "$session")
    limit=$(ping_limit)
    if valid_count "$(read_state max '')"; then
        source_label='this session (/m-keep-warm)'
    elif valid_count "${CLAUDE_KEEP_WARM_PINGS:-}"; then
        source_label='CLAUDE_KEEP_WARM_PINGS'
    else
        source_label='the default'
    fi
    if [ "$limit" -eq 0 ]; then
        printf 'keep-warm: off — set by %s\n' "$source_label"
    else
        printf 'keep-warm: up to %s ping(s) per idle break — set by %s\n' "$limit" "$source_label"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Hook mode

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# After stdin is read, so Claude Code never writes a large event into a pipe
# this copy has already closed.
[ "${1:-}" = "--machine-wide" ] && project_registers_own_hook && exit 0

session=$(json_field session_id)
valid_session "$session" || exit 0
event=$(json_field hook_event_name)
dir=$(state_dir_for "$session")
# Taken first, before any other state read: activity stamped after this moment
# supersedes the wait this Stop may arm, even when that activity's own hook ran
# before this one got to bump `gen`.
started_at=$(date +%s)

case "$event" in
    UserPromptSubmit)
        # The ping delivered back to us: recognised by its text, and — should
        # a future Claude Code drop the text — by arriving right after a ping.
        # One-shot: the first prompt after a ping is taken as its echo, and
        # clears pinged_at so a real prompt a few seconds later still resets.
        # The echo carries the machine signature "[keep-warm ping] <digit>…/<digit>"
        # (a case glob, so "[0-9]*" is one digit then anything); a developer
        # merely quoting the bare marker is a real prompt.
        case "$input" in *"$PING_MARKER "[0-9]*/[0-9]*) write_state pinged_at 0; exit 0 ;; esac
        pinged_at=$(read_state pinged_at 0)
        if [ "$pinged_at" -gt 0 ] 2>/dev/null && [ $(( started_at - pinged_at )) -le "$echo_window" ]; then
            write_state pinged_at 0
            exit 0
        fi
        stamp_activity
        bump_gen
        write_state pings 0
        write_state stopped 0
        write_state handoff 0
        exit 0
        ;;
    PreToolUse)
        # Registered for Agent|Task only: the main session's request that
        # spawns a subagent is main-session activity NOW — the spawn's
        # PostToolUse arrives only when the subagent finishes, maybe an hour on.
        from_subagent && exit 0
        stamp_activity
        exit 0
        ;;
    PostToolUse)
        # Only the main session's own calls count: a subagent's requests never
        # refresh the main session's cache, and the handoff rule is about the
        # main session's last tool call.
        from_subagent && exit 0
        stamp_activity
        wrote_handoff=0
        case "$input" in
            *HANDOFF.md*)
                if command -v jq >/dev/null 2>&1; then
                    target=$(printf '%s' "$input" | jq -r 'select(.tool_name == "Write" or .tool_name == "Edit" or .tool_name == "MultiEdit") | .tool_input.file_path // empty' 2>/dev/null)
                    [ "$target" = "${CLAUDE_PROJECT_DIR:-}/HANDOFF.md" ] && wrote_handoff=1
                fi
                ;;
        esac
        if [ "$wrote_handoff" -eq 1 ]; then
            write_state handoff 1
        elif [ "$(read_state handoff 0)" = 1 ]; then
            write_state handoff 0
        fi
        exit 0
        ;;
    StopFailure)
        bump_gen
        write_state stopped 1
        exit 0
        ;;
    SessionEnd)
        bump_gen
        exit 0
        ;;
    Stop) ;;
    *) exit 0 ;;
esac

# --- Stop: decide, then wait ---------------------------------------------------

[ "$(read_state stopped 0)" = 1 ] && exit 0
[ "$(read_state handoff 0)" = 1 ] && exit 0
limit=$(ping_limit)
pings=$(read_state pings 0)
case "$pings" in ''|*[!0-9]*) exit 0 ;; esac
[ "$pings" -lt "$limit" ] || exit 0
on_one_hour_cache || exit 0
claude_version_ok || exit 0

# Fail closed: a gen that did not land could never be superseded.
bump_gen || exit 0
my_gen=$(read_state gen 0)
if [ "$pings" -eq 0 ]; then wait_seconds=$first_wait; else wait_seconds=$next_wait; fi
deadline=$(( started_at + wait_seconds ))

# Keep a Mac from idle-sleeping while this wait runs; caffeinate exits with us.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w "$$" >/dev/null 2>&1 &
fi

still_mine() {
    [ "$(read_state gen 0)" = "$my_gen" ] || return 1
    [ "$(read_state activity_at 0)" -le "$started_at" ] 2>/dev/null || return 1
    if [ -n "${CLAUDE_PID:-}" ]; then
        kill -0 "$CLAUDE_PID" 2>/dev/null || return 1
    fi
    return 0
}

# The wait and everything after it run inside a function called on the last
# line: bash parses a function whole before running it, so a copy of this file
# rewritten in place during the wait (toolkit-sync keeps the inode) cannot feed
# the rest of this run from another version at the old byte offset.
wait_then_ping() {
    while :; do
        still_mine || exit 0
        now=$(date +%s)
        [ "$now" -lt "$deadline" ] || break
        remaining=$(( deadline - now ))
        sleep $(( remaining < poll_seconds ? remaining : poll_seconds ))
    done

    # Resumed long after the deadline (the Mac slept): the cache has presumably
    # expired, so a ping would pay the full rebuild with nobody there.
    if [ $(( now - deadline )) -gt "$late_grace" ]; then
        write_state stopped 1
        exit 0
    fi

    pings=$(( pings + 1 ))
    write_state pings "$pings" || exit 0
    write_state pinged_at "$(date +%s)"
    printf '%s %s/%s — the developer seems to be away; this only keeps the prompt cache warm. If it reached you between tool calls of a turn you are still running, ignore it and continue that turn. If it woke you after your last reply, reply with the single word ok and call no tools — do not resume unfinished work or check on background tasks.\n' \
        "$PING_MARKER" "$pings" "$limit" >&2
    exit 2
}

wait_then_ping
