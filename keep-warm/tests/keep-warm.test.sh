#!/usr/bin/env bash
#
# Fixture tests for keep-warm/keep-warm.sh.
#
# Plain bash, no framework: each case feeds hook events (JSON on stdin) to the
# script with second-scale delays and a temp state dir, then asserts on the exit
# code, stdout / stderr and how long the wait took. A fake `claude` (version
# check) and a fake `caffeinate` sit first on PATH so nothing real is touched.
# Takes about a minute — the waits are real. Run it after any edit to the hook;
# nothing else exercises it.
#
#   bash keep-warm/tests/keep-warm.test.sh
#
# Exit 0 when every case passes, 1 when any case fails.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/keep-warm.sh"

TMP="$(mktemp -d)"
trap 'jobs -p | xargs kill 2>/dev/null; rm -rf "$TMP"' EXIT

export CLAUDE_PROJECT_DIR="$TMP/repo"
mkdir -p "$CLAUDE_PROJECT_DIR" "$TMP/bin"
export CLAUDE_KEEP_WARM_STATE_DIR="$TMP/state"
export CLAUDE_KEEP_WARM_FIRST_SECONDS=1
export CLAUDE_KEEP_WARM_NEXT_SECONDS=1
export CLAUDE_KEEP_WARM_POLL_SECONDS=1
unset CLAUDE_KEEP_WARM_PINGS CLAUDE_KEEP_WARM_LATE_GRACE_SECONDS CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS CLAUDE_PID
# The cache-lifetime signals the hook reads — the developer's own shell must
# not leak them into the cases that do not set them.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    CLAUDE_CODE_USE_FOUNDRY ENABLE_PROMPT_CACHING_1H ENABLE_PROMPT_CACHING_1H_BEDROCK \
    FORCE_PROMPT_CACHING_5M CLAUDE_CODE_PROMPT_CACHE_TTL CLAUDE_CODE_USE_ANTHROPIC_AWS \
    CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE

# Fake `claude`: prints the version held in $TMP/claude-version (the version
# guard reads `claude --version`). Fake `caffeinate`: records its arguments.
printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
cat "$TMP/claude-version"
EOF
cat > "$TMP/bin/caffeinate" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/caffeinate-calls"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/caffeinate"
export PATH="$TMP/bin:$PATH"

pass_count=0
fail_count=0

pass() {
    printf 'PASS %s\n' "$1"
    pass_count=$((pass_count + 1))
}

fail() {
    printf 'FAIL %s: %s\n' "$1" "$2"
    fail_count=$((fail_count + 1))
}

# Hook events. $1 = session id; extra fields per event.
ev_stop()        { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$1"; }
ev_failure()     { printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"overloaded"}' "$1"; }
ev_end()         { printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"clear"}' "$1"; }
ev_prompt()      { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" "$2"; }
ev_write()       { printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"tool_response":{}}' "$1" "$2"; }
ev_sub_write()   { printf '{"session_id":"%s","hook_event_name":"PostToolUse","agent_id":"a1","agent_type":"m-coder","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"tool_response":{}}' "$1" "$2"; }
ev_pre_agent()   { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"m-coder","prompt":"x"}}' "$1"; }
ev_sub_pre_agent() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","agent_id":"a1","agent_type":"m-coder","tool_name":"Agent","tool_input":{"subagent_type":"m-scout","prompt":"x"}}' "$1"; }
ev_nested_id()   { printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"mcp__team__spawn","tool_input":{},"tool_response":{"data":{"agent_id":"t1"}}}' "$1"; }
ev_bash()        { printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"tool_response":{}}' "$1"; }

# Runs the hook in the foreground with $1 on stdin and any further arguments on
# its command line; sets out / err / code / elapsed (whole seconds).
run_hook() {
    local stdin_data="$1" started
    shift
    started=$(date +%s)
    out="$(printf '%s' "$stdin_data" | bash "$HOOK" "$@" 2>"$TMP/err")"
    code=$?
    err="$(cat "$TMP/err")"
    elapsed=$(( $(date +%s) - started ))
}

# Starts the hook in the background with $1 on stdin and any arguments after
# $2 on its command line; its exit code lands in $TMP/bg-<tag>.code and its
# stderr in $TMP/bg-<tag>.err.
run_hook_bg() {
    local stdin_data="$1" tag="$2"
    shift 2
    rm -f "$TMP/bg-$tag.code" "$TMP/bg-$tag.err"
    ( printf '%s' "$stdin_data" | bash "$HOOK" "$@" >"$TMP/bg-$tag.out" 2>"$TMP/bg-$tag.err"; echo $? > "$TMP/bg-$tag.code" ) &
}

# Waits up to $2 seconds for background hook $1 to finish; prints its exit code.
wait_bg() {
    local tag="$1" limit="$2" i=0
    while [ ! -s "$TMP/bg-$tag.code" ] && [ "$i" -lt $((limit * 10)) ]; do
        sleep 0.1
        i=$((i + 1))
    done
    cat "$TMP/bg-$tag.code" 2>/dev/null || echo "still-running"
}

# A ping = exit 2 with the ping marker on stderr and nothing on stdout.
is_ping() {
    [ "$code" -eq 2 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q '\[keep-warm ping\]'
}

# No ping = exit 0 at once (no wait armed), silent.
is_quiet_skip() {
    [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && [ "$elapsed" -le 1 ]
}

# --- the core cycle -----------------------------------------------------------
name='test_stop_when_session_goes_idle_should_ping_after_first_delay'
CLAUDE_KEEP_WARM_FIRST_SECONDS=2 run_hook "$(ev_stop idle1)"
if is_ping && [ "$elapsed" -ge 2 ]; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err out=$out"; fi

name='test_later_pings_when_chain_continues_should_use_next_delay'
run_hook "$(ev_stop next1)"
first_code=$code
CLAUDE_KEEP_WARM_NEXT_SECONDS=3 run_hook "$(ev_stop next1)"
if [ "$first_code" -eq 2 ] && is_ping && [ "$elapsed" -ge 3 ]; then pass "$name"; else fail "$name" "first=$first_code code=$code elapsed=$elapsed"; fi

name='test_pings_when_default_limit_reached_should_stop_arming'
run_hook "$(ev_stop limit1)"; c1=$code
run_hook "$(ev_stop limit1)"; c2=$code
run_hook "$(ev_stop limit1)"; c3=$code
run_hook "$(ev_stop limit1)"
if [ "$c1$c2$c3" = "222" ] && is_quiet_skip; then pass "$name"; else fail "$name" "codes=$c1$c2$c3 then code=$code elapsed=$elapsed"; fi

# --- activity cancels and resets ----------------------------------------------
name='test_prompt_when_wait_is_armed_should_cancel_it_silently'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop cancel1)" cancel1
sleep 1
run_hook "$(ev_prompt cancel1 'next task')"
bg_code=$(wait_bg cancel1 4)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-cancel1.err" ] && [ "$code" -eq 0 ] && [ -z "$out$err" ]; then
    pass "$name"
else
    fail "$name" "bg=$bg_code bg_err=$(cat "$TMP/bg-cancel1.err") prompt_code=$code"
fi

name='test_second_turn_end_when_first_wait_is_armed_should_supersede_it'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop super1)" super1a
sleep 1
CLAUDE_KEEP_WARM_FIRST_SECONDS=2 run_hook_bg "$(ev_stop super1)" super1b
a_code=$(wait_bg super1a 5)
b_code=$(wait_bg super1b 5)
if [ "$a_code" = "0" ] && [ ! -s "$TMP/bg-super1a.err" ] && [ "$b_code" = "2" ]; then
    pass "$name"
else
    fail "$name" "first=$a_code second=$b_code"
fi

name='test_prompt_when_limit_was_reached_should_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop reset1)"; c1=$code
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop reset1)"; skipped=$code
sleep 2   # past the (shortened) window in which a prompt counts as the ping's own echo
CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS=1 run_hook "$(ev_prompt reset1 'back from lunch')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop reset1)"
if [ "$c1" = "2" ] && [ "$skipped" = "0" ] && is_ping; then pass "$name"; else fail "$name" "c1=$c1 skipped=$skipped code=$code"; fi

# Claude Code delivers the ping as a UserPromptSubmit event (observed live).
name='test_ping_text_when_it_arrives_as_a_prompt_should_not_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo1)"
run_hook "$(ev_prompt echo1 '[keep-warm ping] 1/1 — reply ok')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo1)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# If a future Claude Code delivers the ping without its text, the timing alone
# must still keep the ping from resetting the count.
name='test_prompt_right_after_a_ping_without_the_marker_should_not_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo2)"
run_hook "$(ev_prompt echo2 '<task-notification>keep-warm ping</task-notification>')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo2)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# The echo must be recognised by its text alone — here it arrives after the
# (shortened) timing window, so only the signature match can keep the count.
name='test_ping_text_arriving_after_the_echo_window_should_not_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo5)"
sleep 2
CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS=1 run_hook "$(ev_prompt echo5 '[keep-warm ping] 1/1 — reply ok')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo5)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# A developer quoting the marker in a real message is not the echo — only the
# full machine signature ("[keep-warm ping] n/m — ") is.
name='test_real_prompt_quoting_the_marker_should_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop quote1)"
run_hook "$(ev_prompt quote1 '[keep-warm ping] 1/1 — the developer seems to be away')"
run_hook "$(ev_prompt quote1 'why did the [keep-warm ping] fire at 3pm')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop quote1)"
if is_ping; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# The echo is one-shot: once the ping's own echo has arrived, a real prompt a
# few seconds later is the developer, and must reset the count.
name='test_real_prompt_after_the_pings_echo_should_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo3)"
run_hook "$(ev_prompt echo3 '[keep-warm ping] 1/1 — reply ok')"
run_hook "$(ev_prompt echo3 'I am back, fix the bug')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo3)"
if is_ping; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

name='test_real_prompt_after_a_markerless_echo_should_reset_the_count'
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo4)"
run_hook "$(ev_prompt echo4 '<task-notification>keep-warm ping</task-notification>')"
run_hook "$(ev_prompt echo4 'I am back')"
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop echo4)"
if is_ping; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# A message queued during a turn is submitted the instant the turn ends, so its
# prompt can race the Stop hook arming the wait. Whatever the order, activity
# after the wait started must cancel it.
name='test_prompt_racing_the_turn_end_then_new_activity_should_cancel_the_wait'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop race1)" race1
run_hook "$(ev_prompt race1 'queued message')"
sleep 1.2
run_hook "$(ev_bash race1)"
bg_code=$(wait_bg race1 5)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-race1.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code err=$(cat "$TMP/bg-race1.err")"; fi

# A new turn that goes straight into a long foreground subagent: the main
# session's request happened at spawn time, so the spawn must cancel a stale
# wait (the subagent's own calls are ignored, and its completion comes late).
name='test_main_session_spawning_a_subagent_should_cancel_a_stale_wait'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop spawn1)" spawn1
run_hook "$(ev_prompt spawn1 'queued message')"
sleep 1.2
run_hook "$(ev_pre_agent spawn1)"
bg_code=$(wait_bg spawn1 5)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-spawn1.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code err=$(cat "$TMP/bg-spawn1.err")"; fi

name='test_subagent_spawning_a_subagent_should_not_cancel_the_wait'
CLAUDE_KEEP_WARM_FIRST_SECONDS=3 run_hook_bg "$(ev_stop spawn2)" spawn2
sleep 1.2
run_hook "$(ev_sub_pre_agent spawn2)"
bg_code=$(wait_bg spawn2 5)
if [ "$bg_code" = "2" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

# Only the TOP-LEVEL agent_id marks a subagent call; a main-session tool whose
# response happens to carry an agent_id key is still main-session activity.
name='test_main_session_call_with_a_nested_agent_id_should_still_cancel_the_wait'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop nested1)" nested1
sleep 1.2
run_hook "$(ev_nested_id nested1)"
bg_code=$(wait_bg nested1 5)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-nested1.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

# Only main-session requests refresh the main session's cache, so a background
# subagent at work must not cancel the wait that keeps that cache warm.
name='test_subagent_activity_during_the_wait_should_not_cancel_it'
CLAUDE_KEEP_WARM_FIRST_SECONDS=3 run_hook_bg "$(ev_stop race2)" race2
sleep 1.2
run_hook "$(ev_sub_write race2 "$CLAUDE_PROJECT_DIR/notes.md")"
bg_code=$(wait_bg race2 5)
if [ "$bg_code" = "2" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

name='test_main_session_tool_call_during_the_wait_should_cancel_it'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop race3)" race3
sleep 1.2
run_hook "$(ev_bash race3)"
bg_code=$(wait_bg race3 5)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-race3.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

# --- a ping that would land after the cache expired -----------------------------
# A sleeping Mac pauses the wait; on wake the deadline is long past and the
# cache is gone, so pinging would pay the full rebuild with nobody there.
name='test_wait_resumed_long_after_its_deadline_should_stop_the_chain_silently'
printf '%s' "$(ev_stop late1)" > "$TMP/late1.json"
CLAUDE_KEEP_WARM_FIRST_SECONDS=2 CLAUDE_KEEP_WARM_LATE_GRACE_SECONDS=1 \
    bash "$HOOK" < "$TMP/late1.json" > "$TMP/late1.out" 2> "$TMP/late1.err" &
late_pid=$!
sleep 0.5
kill -STOP "$late_pid"
sleep 5
kill -CONT "$late_pid"
wait "$late_pid"
late_code=$?
run_hook "$(ev_stop late1)"
if [ "$late_code" -eq 0 ] && [ ! -s "$TMP/late1.err" ] && is_quiet_skip; then
    pass "$name"
else
    fail "$name" "late_code=$late_code err=$(cat "$TMP/late1.err") next_stop=$code elapsed=$elapsed"
fi

name='test_prompt_after_a_late_wake_stop_should_rearm_pings'
run_hook "$(ev_prompt late1 'back at my desk')"
run_hook "$(ev_stop late1)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# --- sessions on the 5-minute cache -------------------------------------------------
# Only subscribers get the 1-hour cache by default; on the 5-minute one every
# ping would pay a full rebuild instead of a read.
for signal in 'FORCE_PROMPT_CACHING_5M=1' 'ANTHROPIC_API_KEY=sk-test' 'ANTHROPIC_AUTH_TOKEN=tok' \
    'CLAUDE_CODE_USE_BEDROCK=1' 'CLAUDE_CODE_USE_VERTEX=1' 'CLAUDE_CODE_USE_FOUNDRY=1' \
    'CLAUDE_CODE_USE_ANTHROPIC_AWS=1' 'CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD=1' 'CLAUDE_CODE_USE_MANTLE=1' \
    'CLAUDE_CODE_PROMPT_CACHE_TTL=5m'; do
    name="test_session_on_the_five_minute_cache_should_not_ping:[$signal]"
    printf '%s' "$(ev_stop "ttl-${signal%%=*}")" > "$TMP/ttl.json"
    started=$(date +%s)
    env "$signal" bash "$HOOK" < "$TMP/ttl.json" > "$TMP/ttl.out" 2> "$TMP/ttl.err"; code=$?
    elapsed=$(( $(date +%s) - started ))
    out=$(cat "$TMP/ttl.out"); err=$(cat "$TMP/ttl.err")
    if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi
done

# Claude Code (2.1.283) decides in this order: a forced 5 min, the TTL
# variable ("5m" / "1h"), the 1-hour switches, then not-a-subscriber → 5 min.
# These combinations pin that order; a switch set to "0" counts as unset.
for signal in 'ENABLE_PROMPT_CACHING_1H=1 CLAUDE_CODE_PROMPT_CACHE_TTL=5m' 'ANTHROPIC_API_KEY=sk-test ENABLE_PROMPT_CACHING_1H=0' \
    'FORCE_PROMPT_CACHING_5M=true CLAUDE_CODE_PROMPT_CACHE_TTL=1h' 'ANTHROPIC_API_KEY=sk-test CLAUDE_CODE_PROMPT_CACHE_TTL=1H' \
    'FORCE_PROMPT_CACHING_5M=ON'; do
    name="test_cache_signals_that_resolve_to_five_minutes_should_not_ping:[$signal]"
    printf '%s' "$(ev_stop "ttl5c-${signal%%=*}")" > "$TMP/ttl.json"
    started=$(date +%s)
    # shellcheck disable=SC2086
    env $signal bash "$HOOK" < "$TMP/ttl.json" > "$TMP/ttl.out" 2> "$TMP/ttl.err"; code=$?
    elapsed=$(( $(date +%s) - started ))
    out=$(cat "$TMP/ttl.out"); err=$(cat "$TMP/ttl.err")
    if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi
done

for signal in 'ANTHROPIC_API_KEY=sk-test ENABLE_PROMPT_CACHING_1H=1' 'CLAUDE_CODE_USE_BEDROCK=1 ENABLE_PROMPT_CACHING_1H_BEDROCK=1' \
    'ANTHROPIC_API_KEY=sk-test CLAUDE_CODE_PROMPT_CACHE_TTL=1h' 'CLAUDE_CODE_PROMPT_CACHE_TTL=1h' \
    'ANTHROPIC_API_KEY=sk-test ENABLE_PROMPT_CACHING_1H=TRUE' 'CLAUDE_CODE_PROMPT_CACHE_TTL=2h'; do
    name="test_session_forced_onto_the_one_hour_cache_should_ping:[$signal]"
    printf '%s' "$(ev_stop "ttl1h-${signal%%=*}")" > "$TMP/ttl.json"
    # shellcheck disable=SC2086
    env $signal bash "$HOOK" < "$TMP/ttl.json" > "$TMP/ttl.out" 2> "$TMP/ttl.err"; code=$?
    out=$(cat "$TMP/ttl.out"); err=$(cat "$TMP/ttl.err")
    if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi
done

name='test_forced_five_minutes_with_padding_should_not_ping'
printf '%s' "$(ev_stop ttlpad)" > "$TMP/ttl.json"
started=$(date +%s)
FORCE_PROMPT_CACHING_5M='1 ' bash "$HOOK" < "$TMP/ttl.json" > "$TMP/ttl.out" 2> "$TMP/ttl.err"; code=$?
elapsed=$(( $(date +%s) - started )); out=$(cat "$TMP/ttl.out"); err=$(cat "$TMP/ttl.err")
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

# --- state that cannot be written ------------------------------------------------------
# If the hook cannot record its state, nothing could cancel a wait or end the
# chain — so it must not ping at all.
name='test_state_dir_not_writable_should_never_ping'
mkdir -p "$TMP/readonly-state"
chmod 555 "$TMP/readonly-state"
CLAUDE_KEEP_WARM_STATE_DIR="$TMP/readonly-state" run_hook "$(ev_stop ro1)"
chmod 755 "$TMP/readonly-state"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

# --- failure stops the chain --------------------------------------------------
name='test_turn_end_after_api_failure_should_not_ping'
run_hook "$(ev_failure fail1)"
run_hook "$(ev_stop fail1)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_prompt_after_api_failure_should_rearm_pings'
run_hook "$(ev_prompt fail1 'retry')"
run_hook "$(ev_stop fail1)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_api_failure_when_wait_is_armed_should_cancel_it'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop fail2)" fail2
sleep 1
run_hook "$(ev_failure fail2)"
bg_code=$(wait_bg fail2 4)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-fail2.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

# --- HANDOFF.md skip ------------------------------------------------------------
name='test_turn_whose_last_tool_call_wrote_handoff_should_not_ping'
run_hook "$(ev_write hand1 "$CLAUDE_PROJECT_DIR/HANDOFF.md")"
run_hook "$(ev_stop hand1)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_handoff_followed_by_another_tool_call_should_still_ping'
run_hook "$(ev_write hand2 "$CLAUDE_PROJECT_DIR/HANDOFF.md")"
run_hook "$(ev_bash hand2)"
run_hook "$(ev_stop hand2)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_subagent_tool_call_after_the_handoff_should_still_skip'
run_hook "$(ev_write hand5 "$CLAUDE_PROJECT_DIR/HANDOFF.md")"
run_hook "$(ev_sub_write hand5 "$CLAUDE_PROJECT_DIR/notes.md")"
run_hook "$(ev_stop hand5)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_handoff_written_by_a_subagent_should_still_ping'
run_hook "$(ev_sub_write hand3 "$CLAUDE_PROJECT_DIR/HANDOFF.md")"
run_hook "$(ev_stop hand3)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_handoff_file_outside_the_project_root_should_still_ping'
run_hook "$(ev_write hand4 "$CLAUDE_PROJECT_DIR/docs/HANDOFF.md")"
run_hook "$(ev_stop hand4)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_prompt_after_a_handoff_turn_should_rearm_pings'
run_hook "$(ev_prompt hand1 'actually one more thing')"
run_hook "$(ev_stop hand1)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# --- configuration --------------------------------------------------------------
name='test_env_count_zero_should_disable_pings'
CLAUDE_KEEP_WARM_PINGS=0 run_hook "$(ev_stop env0)"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_env_count_invalid_should_fall_back_to_default'
CLAUDE_KEEP_WARM_PINGS=abc run_hook "$(ev_stop envbad)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_set_off_should_disable_only_that_session'
bash "$HOOK" set off1 off >/dev/null 2>&1; set_code=$?
run_hook "$(ev_stop off1)"; off_code=$code; off_elapsed=$elapsed
run_hook "$(ev_stop off2)"
if [ "$set_code" -eq 0 ] && [ "$off_code" -eq 0 ] && [ "$off_elapsed" -le 1 ] && is_ping; then
    pass "$name"
else
    fail "$name" "set=$set_code off_session=$off_code other_session=$code"
fi

name='test_set_count_should_override_the_env_default'
set_out=$(bash "$HOOK" set over1 2 2>&1); set_code=$?
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop over1)"; c1=$code
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop over1)"; c2=$code
CLAUDE_KEEP_WARM_PINGS=1 run_hook "$(ev_stop over1)"
if [ "$set_code" -eq 0 ] && printf '%s' "$set_out" | grep -q '2' && [ "$c1$c2" = "22" ] && is_quiet_skip; then
    pass "$name"
else
    fail "$name" "set=$set_code out=$set_out codes=$c1$c2 third=$code"
fi

# The /m-keep-warm message must tell the truth about the waits in effect, not
# restate the defaults.
name='test_set_message_should_report_the_waits_in_effect'
set_out=$(CLAUDE_KEEP_WARM_FIRST_SECONDS=120 CLAUDE_KEEP_WARM_NEXT_SECONDS=180 bash "$HOOK" set msg1 2 2>&1)
if printf '%s' "$set_out" | grep -q '2 min' && printf '%s' "$set_out" | grep -q '3 min' \
    && printf '%s' "$set_out" | grep -q '1h05m'; then
    pass "$name"
else
    fail "$name" "out=[$set_out]"
fi

name='test_set_message_with_default_waits_should_report_50_and_55_minutes'
set_out=$(env -u CLAUDE_KEEP_WARM_FIRST_SECONDS -u CLAUDE_KEEP_WARM_NEXT_SECONDS bash "$HOOK" set msg2 3 2>&1)
if printf '%s' "$set_out" | grep -q '50 min' && printf '%s' "$set_out" | grep -q '55 min' \
    && printf '%s' "$set_out" | grep -q '3h40m'; then
    pass "$name"
else
    fail "$name" "out=[$set_out]"
fi

# A wait of an hour or more outlives the cache it is meant to keep warm (and
# the hook's timeout), so such an override falls back to the default.
name='test_wait_override_of_an_hour_or_more_should_fall_back_to_the_default'
set_out=$(CLAUDE_KEEP_WARM_FIRST_SECONDS=3600 CLAUDE_KEEP_WARM_NEXT_SECONDS=7200 bash "$HOOK" set msg3 1 2>&1)
if printf '%s' "$set_out" | grep -q '50 min' && printf '%s' "$set_out" | grep -q '55 min'; then
    pass "$name"
else
    fail "$name" "out=[$set_out]"
fi

for bad in abc -1 11 '' 2.5; do
    name="test_set_when_count_is_invalid_should_reject:[$bad]"
    set_err=$(bash "$HOOK" set bad1 "$bad" 2>&1 >/dev/null); set_code=$?
    if [ "$set_code" -ne 0 ] && [ -n "$set_err" ] && [ ! -e "$CLAUDE_KEEP_WARM_STATE_DIR/claude-keep-warm-bad1/max" ]; then
        pass "$name"
    else
        fail "$name" "code=$set_code err=$set_err"
    fi
done

name='test_status_should_report_the_count_and_where_it_comes_from'
bash "$HOOK" set stat1 4 >/dev/null 2>&1
session_status=$(bash "$HOOK" status stat1 2>&1)
env_status=$(CLAUDE_KEEP_WARM_PINGS=2 bash "$HOOK" status stat2 2>&1)
default_status=$(bash "$HOOK" status stat3 2>&1)
if printf '%s' "$session_status" | grep -q '4 ping' && printf '%s' "$session_status" | grep -q 'session' \
    && printf '%s' "$env_status" | grep -q '2 ping' && printf '%s' "$env_status" | grep -q 'CLAUDE_KEEP_WARM_PINGS' \
    && printf '%s' "$default_status" | grep -q '3 ping' && printf '%s' "$default_status" | grep -q 'default'; then
    pass "$name"
else
    fail "$name" "session=[$session_status] env=[$env_status] default=[$default_status]"
fi

name='test_status_when_off_should_say_off'
bash "$HOOK" set stat4 off >/dev/null 2>&1
off_status=$(bash "$HOOK" status stat4 2>&1)
if printf '%s' "$off_status" | grep -q 'off'; then pass "$name"; else fail "$name" "status=[$off_status]"; fi

name='test_set_when_session_id_is_unsafe_should_reject'
bash "$HOOK" set '../escape' 2 >/dev/null 2>&1; set_code=$?
if [ "$set_code" -ne 0 ] && [ ! -e "$CLAUDE_KEEP_WARM_STATE_DIR/escape" ] && [ ! -e "$TMP/escape" ]; then pass "$name"; else fail "$name" "code=$set_code"; fi

name='test_hook_when_session_id_is_unsafe_should_do_nothing'
run_hook '{"session_id":"../../evil","hook_event_name":"Stop"}'
if is_quiet_skip && [ ! -e "$TMP/evil" ]; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_hook_when_input_is_not_json_should_do_nothing'
run_hook 'not json at all'
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# --- guards -------------------------------------------------------------------------
name='test_old_claude_code_version_should_not_arm'
printf '2.1.200 (Claude Code)\n' > "$TMP/claude-version"
run_hook "$(ev_stop old1)"
printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_newer_claude_code_version_should_arm'
printf '2.2.3 (Claude Code)\n' > "$TMP/claude-version"
run_hook "$(ev_stop new1)"
printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

name='test_unreadable_claude_code_version_should_not_arm'
printf 'garbage\n' > "$TMP/claude-version"
run_hook "$(ev_stop unread1)"
printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
if is_quiet_skip; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed"; fi

name='test_session_end_when_wait_is_armed_should_cancel_it'
CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop end1)" end1
sleep 1
run_hook "$(ev_end end1)"
bg_code=$(wait_bg end1 4)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-end1.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

name='test_claude_code_exit_when_wait_is_armed_should_cancel_it'
sleep 30 &
fake_claude_pid=$!
CLAUDE_PID=$fake_claude_pid CLAUDE_KEEP_WARM_FIRST_SECONDS=4 run_hook_bg "$(ev_stop exit1)" exit1
sleep 1
kill "$fake_claude_pid" 2>/dev/null
wait "$fake_claude_pid" 2>/dev/null
bg_code=$(wait_bg exit1 4)
if [ "$bg_code" = "0" ] && [ ! -s "$TMP/bg-exit1.err" ]; then pass "$name"; else fail "$name" "bg=$bg_code"; fi

name='test_wait_should_keep_the_mac_awake_only_on_macos'
rm -f "$TMP/caffeinate-calls"
run_hook "$(ev_stop caf1)"
calls=$(cat "$TMP/caffeinate-calls" 2>/dev/null)
if [ "$(uname -s)" = "Darwin" ]; then
    if [ "$code" -eq 2 ] && printf '%s' "$calls" | grep -q -- '-i'; then pass "$name"; else fail "$name" "code=$code calls=$calls"; fi
else
    if [ "$code" -eq 2 ] && [ -z "$calls" ]; then pass "$name"; else fail "$name" "code=$code calls=$calls"; fi
fi

# --- the machine-wide copy -----------------------------------------------------------
# keep-warm-install.sh registers a copy for every project, run with
# --machine-wide. Where the project registers its own hook both would fire —
# two waits per turn racing on the same state — so that copy stands down there.
# Each case gets its own project dir; the shared one registers nothing.

# project_with_registration <dir> <settings file name> <command>
project_with_registration() {
    mkdir -p "$1/.claude"
    cat > "$1/.claude/$2" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$3",
            "async": true,
            "asyncRewake": true,
            "timeout": 3600,
            "rewakeMessage": "Message from the keep-warm hook (scripts/claude/keep-warm.sh):",
            "rewakeSummary": "keep-warm ping"
          }
        ]
      }
    ]
  }
}
EOF
}

name='test_machine_wide_copy_when_the_project_registers_its_own_hook_should_do_nothing'
project_with_registration "$TMP/project-own" settings.json '${CLAUDE_PROJECT_DIR}/scripts/claude/keep-warm.sh'
CLAUDE_PROJECT_DIR="$TMP/project-own" run_hook "$(ev_stop mw1)" --machine-wide
if is_quiet_skip && [ ! -e "$CLAUDE_KEEP_WARM_STATE_DIR/claude-keep-warm-mw1" ]; then
    pass "$name"
else
    fail "$name" "code=$code elapsed=$elapsed err=$err state=$(ls "$CLAUDE_KEEP_WARM_STATE_DIR/claude-keep-warm-mw1" 2>/dev/null)"
fi

name='test_machine_wide_copy_when_only_the_local_settings_register_the_hook_should_do_nothing'
project_with_registration "$TMP/project-local" settings.local.json '${CLAUDE_PROJECT_DIR}/scripts/claude/keep-warm.sh'
CLAUDE_PROJECT_DIR="$TMP/project-local" run_hook "$(ev_stop mw2)" --machine-wide
if is_quiet_skip && [ ! -e "$CLAUDE_KEEP_WARM_STATE_DIR/claude-keep-warm-mw2" ]; then
    pass "$name"
else
    fail "$name" "code=$code elapsed=$elapsed err=$err"
fi

name='test_machine_wide_copy_when_the_project_registers_none_should_ping'
mkdir -p "$TMP/project-none/.claude"
printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$TMP/project-none/.claude/settings.json"
CLAUDE_PROJECT_DIR="$TMP/project-none" run_hook "$(ev_stop mw3)" --machine-wide
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# A session started in the home directory reads the user settings as its
# project settings — and they hold only the machine-wide registration, whose
# rewakeMessage still names scripts/claude/keep-warm.sh.
name='test_machine_wide_copy_when_the_project_settings_hold_only_the_machine_wide_registration_should_ping'
project_with_registration "$TMP/home-dir" settings.json 'bash \"/Users/dev/.claude/hooks/keep-warm.sh\" --machine-wide'
CLAUDE_PROJECT_DIR="$TMP/home-dir" run_hook "$(ev_stop mw4)" --machine-wide
if is_ping; then pass "$name"; else fail "$name" "code=$code elapsed=$elapsed err=$err"; fi

name='test_project_copy_when_the_project_registers_the_hook_should_still_ping'
CLAUDE_PROJECT_DIR="$TMP/project-own" run_hook "$(ev_stop mw5)"
if is_ping; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# --- a hook file rewritten while a wait runs ------------------------------------------
# toolkit-sync refreshes the machine-wide copy by rewriting the same file in
# place, and bash reads a script as it goes: a wait armed before the rewrite
# must still finish as the version that armed it.
name='test_hook_file_rewritten_in_place_during_the_wait_should_still_ping_cleanly'
mkdir -p "$TMP/live-copy"
cp "$HOOK" "$TMP/live-copy/keep-warm.sh"
CLAUDE_KEEP_WARM_FIRST_SECONDS=3 HOOK="$TMP/live-copy/keep-warm.sh" run_hook_bg "$(ev_stop inplace1)" inplace1
sleep 1
# Same inode (a redirect, not mv), new content: blank lines well past any byte
# offset the old version could resume at, then a line that betrays itself.
{
    LC_ALL=C tr -c '\n' '\n' < "$HOOK"
    LC_ALL=C tr -c '\n' '\n' < "$HOOK"
    printf 'echo KEEP_WARM_REWRITE_SENTINEL >&2; exit 7\n'
} > "$TMP/live-copy/keep-warm.sh"
bg_code=$(wait_bg inplace1 6)
if [ "$bg_code" = "2" ] && grep -q '\[keep-warm ping\]' "$TMP/bg-inplace1.err" \
    && ! grep -q 'KEEP_WARM_REWRITE_SENTINEL' "$TMP/bg-inplace1.err"; then
    pass "$name"
else
    fail "$name" "bg=$bg_code err=$(cat "$TMP/bg-inplace1.err")"
fi

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
