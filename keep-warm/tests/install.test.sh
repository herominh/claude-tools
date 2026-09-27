#!/usr/bin/env bash
#
# Fixture tests for keep-warm/install.sh.
#
# Plain bash, no framework: each case installs into a fresh config dir under a
# temp dir — CLAUDE_CONFIG_DIR and HOME both point there, so the real ~/.claude
# is never touched — then asserts on the exit code, stderr and the files left
# behind, reading the JSON with jq. A fake `claude` (version check) and a fake
# `caffeinate` sit first on PATH. The end-to-end cases run the registered Stop
# command the way Claude Code does, so they take a few seconds each.
#
#   bash keep-warm/tests/install.test.sh
#
# Exit 0 when every case passes, 1 when any case fails.

set -u

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$SCRIPTS/install.sh"
HOOK_SOURCE="$SCRIPTS/keep-warm.sh"
SKILL_SOURCE="$SCRIPTS/SKILL.md"
# The handlers as a project registers them in its own .claude/settings.json.
PROJECT_SETTINGS="$SCRIPTS/registrations.json"

TMP="$(mktemp -d)"
trap 'jobs -p | xargs kill 2>/dev/null; rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
unset CLAUDE_PROJECT_DIR CLAUDE_KEEP_WARM_PINGS CLAUDE_KEEP_WARM_LATE_GRACE_SECONDS CLAUDE_KEEP_WARM_ECHO_WINDOW_SECONDS CLAUDE_PID
# The cache-lifetime signals the hook reads — the developer's own shell must
# not leak them into the end-to-end cases.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    CLAUDE_CODE_USE_FOUNDRY ENABLE_PROMPT_CACHING_1H ENABLE_PROMPT_CACHING_1H_BEDROCK \
    FORCE_PROMPT_CACHING_5M CLAUDE_CODE_PROMPT_CACHE_TTL CLAUDE_CODE_USE_ANTHROPIC_AWS \
    CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE

# Fake `claude`: prints the version held in $TMP/claude-version. Fake
# `caffeinate`: does nothing.
printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
cat "$TMP/claude-version"
EOF
printf '#!/usr/bin/env bash\n' > "$TMP/bin/caffeinate"
chmod +x "$TMP/bin/claude" "$TMP/bin/caffeinate"
export PATH="$TMP/bin:$PATH"

readonly KEEP_WARM_EVENTS='["PostToolUse","PreToolUse","SessionEnd","Stop","StopFailure","UserPromptSubmit"]'

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

# fresh_config <case> [config dir] — points CLAUDE_CONFIG_DIR at a config dir
# that does not exist yet (default $TMP/<case>/config); sets CONFIG, SETTINGS.
fresh_config() {
    mkdir -p "$TMP/$1"
    CONFIG="${2:-$TMP/$1/config}"
    SETTINGS="$CONFIG/settings.json"
    export CLAUDE_CONFIG_DIR="$CONFIG"
}

# Runs the installer with the given arguments; sets out / err / code.
run_installer() {
    out="$(bash "$INSTALLER" "$@" 2>"$TMP/err")"
    code=$?
    err="$(cat "$TMP/err")"
}

# The command the installer registers, as Claude Code will run it.
registered_command() {
    printf 'bash "%s/hooks/keep-warm.sh" --machine-wide' "$CONFIG"
}

# Settings with content that is not ours: permissions, a status line, env and
# unrelated hooks — under keep-warm events (Stop, PreToolUse with a matcher)
# and under others (SessionStart, a Notification group with an extra key, an
# empty PreCompact).
write_other_settings() {
    mkdir -p "$CONFIG"
    cat > "$SETTINGS" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(ls:*)"],
    "deny": ["Bash(rm -rf:*)", "Read(./.env)"]
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"/opt/statusline.sh\"",
    "padding": 0
  },
  "env": {
    "FOO": "1"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/notify-done",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/guard"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/on-start"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "note": "mine",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/notify"
          }
        ]
      }
    ],
    "PreCompact": []
  }
}
EOF
}

# The settings' .hooks with every handler running our command removed, then the
# groups and events that removal emptied — sorted JSON, to compare with the
# .hooks of the file as it was before the install.
hooks_without_ours() {
    jq -S --arg c "$(registered_command)" '
        .hooks // {} | with_entries(
            .value as $groups
            | .value |= map(if any(.hooks[]?; .command == $c)
                            then (.hooks |= map(select(.command != $c)) | select((.hooks | length) > 0))
                            else . end)
            | select((.value | length) > 0 or ($groups | length) == 0))' "$1"
}

# inode <file>
inode() {
    ls -di "$1" | awk '{print $1}'
}

# Temp files an install or uninstall could leave beside the settings.
leftover_temps() {
    (cd "$CONFIG" && ls -A | grep -E '^\.' ; ls -A hooks skills/m-keep-warm 2>/dev/null | grep -E '^\.')
}

# Every file and directory under the config dir, with its size and mode — a
# fingerprint for "nothing was changed".
config_fingerprint() {
    if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
        (cd "$CONFIG" && find . -print | LC_ALL=C sort | while IFS= read -r entry; do
            printf '%s %s\n' "$entry" "$(ls -ld "$entry" | awk '{print $1, $5}')"
        done)
        cat "$SETTINGS" 2>/dev/null
    else
        printf 'absent\n'
    fi
}

# Events carrying exactly one registration of our command, as a sorted JSON list.
registered_events() {
    jq -c --arg c "$(registered_command)" \
        '[.hooks | to_entries[] | select([.value[].hooks[] | select(.command == $c)] | length == 1) | .key] | sort' \
        "$SETTINGS" 2>/dev/null
}

# Number of handlers anywhere in the settings running our command.
registration_count() {
    jq --arg c "$(registered_command)" '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length' "$SETTINGS" 2>/dev/null
}

# Runs the Stop command registered in the settings exactly as Claude Code would
# — through a shell, the Stop event on stdin — from project dir $1; sets
# out / err / code / elapsed. No registered command reads as code 99.
run_registered_stop() {
    local project="$1" session="$2" command started
    command=$(jq -r '.hooks.Stop[].hooks[] | select(.command | contains("keep-warm.sh")) | .command' "$SETTINGS" 2>/dev/null)
    if [ -z "$command" ]; then
        out='' err='no registered Stop command' code=99 elapsed=0
        return
    fi
    started=$(date +%s)
    out="$(printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$session" \
        | CLAUDE_PROJECT_DIR="$project" CLAUDE_KEEP_WARM_STATE_DIR="$TMP/state" \
            CLAUDE_KEEP_WARM_FIRST_SECONDS=1 CLAUDE_KEEP_WARM_POLL_SECONDS=1 \
            bash -c "$command" 2>"$TMP/err")"
    code=$?
    err="$(cat "$TMP/err")"
    elapsed=$(( $(date +%s) - started ))
}

is_ping() {
    [ "$code" -eq 2 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q '\[keep-warm ping\]'
}

# --- install -------------------------------------------------------------------------
name='test_install_when_no_settings_file_exists_should_register_the_six_events'
fresh_config c1
run_installer install
events=$(registered_events)
pre_matcher=$(jq -r --arg c "$(registered_command)" '.hooks.PreToolUse[] | select(any(.hooks[]; .command == $c)) | .matcher // "none"' "$SETTINGS" 2>/dev/null)
post_matcher=$(jq -r --arg c "$(registered_command)" '.hooks.PostToolUse[] | select(any(.hooks[]; .command == $c)) | .matcher // "none"' "$SETTINGS" 2>/dev/null)
if [ "$code" -eq 0 ] && [ "$events" = "$KEEP_WARM_EVENTS" ] && [ "$(registration_count)" = 6 ] \
    && [ "$pre_matcher" = 'Agent|Task' ] && [ "$post_matcher" = none ]; then
    pass "$name"
else
    fail "$name" "code=$code err=$err events=$events pre=$pre_matcher post=$post_matcher"
fi

# Only the `claude` on PATH is version-checked, yet every Claude Code on the
# machine (an IDE extension's bundled copy, a second install) reads the same
# settings file — and an older one skips all of it, deny rules included.
name='test_install_should_warn_that_every_other_claude_code_on_the_machine_needs_the_minimum_version'
fresh_config c1b
run_installer install
min_version=$(sed -n "s/^readonly MIN_CLAUDE_VERSION='\([0-9.]*\)'.*/\1/p" "$HOOK_SOURCE")
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q "IDE extension" \
    && printf '%s' "$out" | grep -q "$min_version or newer" && printf '%s' "$out" | grep -q 'deny rules'; then
    pass "$name"
else
    fail "$name" "code=$code min=$min_version out=$out"
fi

name='test_install_when_settings_hold_other_content_should_preserve_it'
fresh_config c2
write_other_settings
cp "$SETTINGS" "$TMP/c2/original.json"
run_installer install
if [ "$code" -eq 0 ] \
    && [ "$(jq -S 'del(.hooks)' "$TMP/c2/original.json")" = "$(jq -S 'del(.hooks)' "$SETTINGS")" ] \
    && [ "$(jq -S '.hooks' "$TMP/c2/original.json")" = "$(hooks_without_ours "$SETTINGS")" ] \
    && [ "$(registered_events)" = "$KEEP_WARM_EVENTS" ]; then
    pass "$name"
else
    fail "$name" "code=$code err=$err settings=$(cat "$SETTINGS")"
fi

# A Claude Code session starting mid-install must read the old file or the new
# one, never a half-written one: the settings are replaced by rename.
name='test_install_should_replace_the_settings_file_by_rename_and_leave_no_temp_file'
fresh_config c2b
write_other_settings
inode_before=$(inode "$SETTINGS")
run_installer install
inode_after=$(inode "$SETTINGS")
temps=$(leftover_temps)
if [ "$code" -eq 0 ] && [ "$inode_after" != "$inode_before" ] && [ -z "$temps" ] && [ "$(registration_count)" = 6 ]; then
    pass "$name"
else
    fail "$name" "code=$code inodes=$inode_before/$inode_after temps=[$temps]"
fi

name='test_install_when_the_user_mixed_a_handler_into_a_group_with_ours_should_keep_it_through_install_and_uninstall'
fresh_config c2c
mkdir -p "$CONFIG"
jq -n --arg c "$(registered_command)" \
    '{hooks: {Stop: [{hooks: [{type: "command", command: "/usr/local/bin/mine"}, {type: "command", command: $c}]}]}}' > "$SETTINGS"
run_installer install; install_code=$code
kept_after_install=$(jq '[.hooks.Stop[].hooks[] | select(.command == "/usr/local/bin/mine")] | length' "$SETTINGS")
install_count=$(registration_count)
run_installer uninstall
if [ "$install_code" -eq 0 ] && [ "$code" -eq 0 ] && [ "$kept_after_install" = 1 ] && [ "$install_count" = 6 ] \
    && [ "$(jq -c . "$SETTINGS")" = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/mine"}]}]}}' ]; then
    pass "$name"
else
    fail "$name" "codes=$install_code/$code kept=$kept_after_install count=$install_count settings=$(cat "$SETTINGS")"
fi

name='test_install_when_run_twice_should_not_duplicate_registrations'
fresh_config c3
write_other_settings
cp "$SETTINGS" "$TMP/c3/original.json"
run_installer install
run_installer install
if [ "$code" -eq 0 ] && [ "$(registration_count)" = 6 ] && [ "$(registered_events)" = "$KEEP_WARM_EVENTS" ] \
    && [ "$(jq -S '.hooks' "$TMP/c3/original.json")" = "$(hooks_without_ours "$SETTINGS")" ]; then
    pass "$name"
else
    fail "$name" "code=$code count=$(registration_count) settings=$(cat "$SETTINGS")"
fi

name='test_install_should_register_the_stop_hook_as_a_background_rewake'
fresh_config c4
run_installer install
if [ "$code" -eq 0 ] && jq -e --arg c "$(registered_command)" \
    '[.hooks.Stop[].hooks[] | select(.command == $c)] | length == 1 and (.[0] | .async == true and .asyncRewake == true and .timeout == 3600)' \
    "$SETTINGS" >/dev/null; then
    pass "$name"
else
    fail "$name" "code=$code stop=$(jq -c '.hooks.Stop' "$SETTINGS" 2>/dev/null)"
fi

name='test_install_should_copy_the_hook_and_the_skill_byte_for_byte'
fresh_config c5
run_installer install
if [ "$code" -eq 0 ] && cmp -s "$HOOK_SOURCE" "$CONFIG/hooks/keep-warm.sh" \
    && cmp -s "$SKILL_SOURCE" "$CONFIG/skills/m-keep-warm/SKILL.md"; then
    pass "$name"
else
    fail "$name" "code=$code err=$err files=$(cd "$CONFIG" 2>/dev/null && find . -type f)"
fi

name='test_install_should_keep_a_backup_of_the_settings_from_before_the_first_install'
fresh_config c6
write_other_settings
cp "$SETTINGS" "$TMP/c6/original.json"
run_installer install; first_code=$code
run_installer install
if [ "$first_code" -eq 0 ] && [ "$code" -eq 0 ] && cmp -s "$TMP/c6/original.json" "$SETTINGS.keep-warm-backup"; then
    pass "$name"
else
    fail "$name" "codes=$first_code/$code backup=$(cat "$SETTINGS.keep-warm-backup" 2>/dev/null)"
fi

# --- install refuses, changing nothing ------------------------------------------------
# A refusal is ONE line in the installer's own voice — not a shell error.
is_one_refusal_line() {
    [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] && case "$err" in 'keep-warm-install: '*) ;; *) false ;; esac
}

# assert_refused <name> — the installer must exit non-zero with one message and
# leave the config dir exactly as $before recorded it: settings byte for byte,
# no hook copy, no skill copy, no backup, no temp file.
assert_refused() {
    if [ "$code" -ne 0 ] && is_one_refusal_line && [ "$(config_fingerprint)" = "$before" ] \
        && [ ! -e "$CONFIG/hooks/keep-warm.sh" ] && [ ! -e "$CONFIG/skills/m-keep-warm/SKILL.md" ]; then
        pass "$1"
    else
        fail "$1" "code=$code err=$err after=[$(config_fingerprint)] before=[$before]"
    fi
}

name='test_install_when_settings_are_not_valid_json_should_refuse_and_change_nothing'
fresh_config c7
mkdir -p "$CONFIG"
printf '{"permissions": {"deny": ["Bash(rm:*)"],}\n' > "$SETTINGS"
before=$(config_fingerprint)
run_installer install
assert_refused "$name"

c8_case=0
for content in '[]' '{"env": {}} {"env": {}}'; do
    name="test_install_when_settings_top_level_is_not_an_object_should_refuse_and_change_nothing:[$content]"
    c8_case=$((c8_case + 1))
    fresh_config "c8-$c8_case"
    mkdir -p "$CONFIG"
    printf '%s\n' "$content" > "$SETTINGS"
    before=$(config_fingerprint)
    run_installer install
    assert_refused "$name"
done

name='test_install_when_settings_hooks_hold_an_event_that_is_not_an_array_should_refuse_and_change_nothing'
fresh_config c8b
mkdir -p "$CONFIG"
printf '{"hooks": {"Stop": {"type": "command", "command": "x"}}}\n' > "$SETTINGS"
before=$(config_fingerprint)
run_installer install
assert_refused "$name"

# A jq that truncates the new settings document and still exits 0 — the
# installer must check what it built before it replaces anything.
REAL_JQ=$(command -v jq)
mkdir -p "$TMP/badjq-bin"
cat > "$TMP/badjq-bin/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *reduce*) "$REAL_JQ" "\$@" | head -c 20; exit 0 ;;
esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TMP/badjq-bin/jq"

name='test_install_when_the_new_settings_document_is_broken_should_refuse_and_change_nothing'
fresh_config c8c
write_other_settings
before=$(config_fingerprint)
out="$(PATH="$TMP/badjq-bin:$PATH" bash "$INSTALLER" install 2>"$TMP/err")"; code=$?
err="$(cat "$TMP/err")"
assert_refused "$name"

for version in '2.1.200 (Claude Code)' 'garbage'; do
    name="test_install_when_claude_code_is_too_old_should_refuse_and_change_nothing:[$version]"
    fresh_config "c9-${version%% *}"
    write_other_settings
    before=$(config_fingerprint)
    printf '%s\n' "$version" > "$TMP/claude-version"
    run_installer install
    printf '2.1.281 (Claude Code)\n' > "$TMP/claude-version"
    assert_refused "$name"
done

# A PATH holding every tool the installer uses except jq.
mkdir -p "$TMP/nojq-bin"
for tool in bash dirname cat cp mv mkdir mktemp chmod rm rmdir grep sed head tr ls; do
    ln -s "$(command -v "$tool")" "$TMP/nojq-bin/$tool"
done
ln -s "$TMP/bin/claude" "$TMP/nojq-bin/claude"

for with_settings in no yes; do
    name="test_install_when_jq_is_missing_should_refuse_and_change_nothing:[settings file: $with_settings]"
    fresh_config "c10-$with_settings"
    [ "$with_settings" = yes ] && write_other_settings
    before=$(config_fingerprint)
    out="$(PATH="$TMP/nojq-bin" bash "$INSTALLER" install 2>"$TMP/err")"; code=$?
    err="$(cat "$TMP/err")"
    if printf '%s' "$err" | grep -q 'jq' && ! printf '%s' "$err" | grep -q 'command not found'; then
        assert_refused "$name"
    else
        fail "$name" "the message does not name jq as the problem: $err"
    fi
done

name='test_install_when_settings_file_is_a_symlink_should_refuse_and_change_nothing'
fresh_config c11
mkdir -p "$CONFIG"
printf '{"env": {"FOO": "1"}}\n' > "$TMP/c11/dotfiles-settings.json"
ln -s "$TMP/c11/dotfiles-settings.json" "$SETTINGS"
before="$(config_fingerprint)$(cat "$TMP/c11/dotfiles-settings.json")"
run_installer install
after="$(config_fingerprint)$(cat "$TMP/c11/dotfiles-settings.json")"
if [ "$code" -ne 0 ] && is_one_refusal_line && [ -L "$SETTINGS" ] && [ "$after" = "$before" ] \
    && [ ! -e "$CONFIG/hooks/keep-warm.sh" ] && [ ! -e "$CONFIG/skills/m-keep-warm/SKILL.md" ]; then
    pass "$name"
else
    fail "$name" "code=$code err=$err"
fi

# 600 and 640: a new file built by mktemp is 600 and one built by a plain
# redirect follows the umask, so only both modes prove the original's are kept.
# The backup is a full copy of the same file (tokens under "env" included), so
# it must not be more readable than the original.
for mode in 600 640; do
    name="test_install_should_keep_the_settings_file_permissions_on_the_file_and_its_backup:[$mode]"
    fresh_config "c12-$mode"
    write_other_settings
    chmod "$mode" "$SETTINGS"
    expected=$(ls -l "$SETTINGS" | awk '{print $1}')
    run_installer install
    actual=$(ls -l "$SETTINGS" | awk '{print $1}')
    backup_mode=$(ls -l "$SETTINGS.keep-warm-backup" 2>/dev/null | awk '{print $1}')
    if [ "$code" -eq 0 ] && [ "$actual" = "$expected" ] && [ "$backup_mode" = "$expected" ] \
        && [ "$(registration_count)" = 6 ]; then
        pass "$name"
    else
        fail "$name" "code=$code expected=$expected actual=$actual backup=$backup_mode"
    fi
done

# The path lands inside a shell command in the settings file.
for char in '$' '"' '`' '\'; do
    name="test_install_when_config_dir_path_holds_a_shell_metacharacter_should_refuse:[$char]"
    fresh_config c17 "$TMP/c17/conf${char}ig"
    run_installer install
    if [ "$code" -ne 0 ] && is_one_refusal_line && [ ! -e "$CONFIG" ]; then
        pass "$name"
    else
        fail "$name" "code=$code err=$err"
    fi
done

# --- uninstall -------------------------------------------------------------------------
name='test_uninstall_should_remove_only_its_own_registrations_and_files'
fresh_config c13
write_other_settings
cp "$SETTINGS" "$TMP/c13/original.json"
# The developer's own files beside ours — the settings backup does not cover them.
foreign_files='hooks/other-hook.sh skills/other/SKILL.md skills/m-keep-warm/notes.md CLAUDE.md'
mkdir -p "$CONFIG/hooks" "$CONFIG/skills/other" "$CONFIG/skills/m-keep-warm" "$TMP/c13/foreign"
for file in $foreign_files; do
    printf 'mine: %s\n' "$file" > "$CONFIG/$file"
done
cp -R "$CONFIG/hooks" "$CONFIG/skills" "$CONFIG/CLAUDE.md" "$TMP/c13/foreign/"
# foreign_intact — every foreign file still present, byte for byte.
foreign_intact() {
    local file
    for file in $foreign_files; do
        cmp -s "$TMP/c13/foreign/$file" "$CONFIG/$file" || return 1
    done
}
run_installer install; install_code=$code
foreign_intact && intact_after_install=yes || intact_after_install=no
run_installer uninstall
if [ "$install_code" -eq 0 ] && [ "$code" -eq 0 ] && [ "$intact_after_install" = yes ] && foreign_intact \
    && [ "$(jq -S . "$TMP/c13/original.json")" = "$(jq -S . "$SETTINGS")" ] \
    && [ ! -e "$CONFIG/hooks/keep-warm.sh" ] && [ ! -e "$CONFIG/skills/m-keep-warm/SKILL.md" ] \
    && [ -f "$SETTINGS.keep-warm-backup" ]; then
    pass "$name"
else
    fail "$name" "codes=$install_code/$code intact-after-install=$intact_after_install err=$err files=$(cd "$CONFIG" && find . | sort | tr '\n' ' ')"
fi

name='test_uninstall_when_install_created_the_settings_file_should_leave_no_hooks_key'
fresh_config c13b
run_installer install; install_code=$code
run_installer uninstall
if [ "$install_code" -eq 0 ] && [ "$code" -eq 0 ] && [ "$(jq -c . "$SETTINGS")" = '{}' ]; then
    pass "$name"
else
    fail "$name" "codes=$install_code/$code settings=$(cat "$SETTINGS" 2>/dev/null)"
fi

name='test_uninstall_when_nothing_is_installed_should_succeed'
fresh_config c14
run_installer uninstall; no_config_code=$code
write_other_settings
before=$(config_fingerprint)
run_installer uninstall
if [ "$no_config_code" -eq 0 ] && [ "$code" -eq 0 ] && [ -n "$out" ] && [ "$(config_fingerprint)" = "$before" ]; then
    pass "$name"
else
    fail "$name" "codes=$no_config_code/$code out=$out err=$err"
fi

name='test_uninstall_when_settings_are_not_valid_json_should_refuse_and_change_nothing'
fresh_config c14b
run_installer install
printf '{"hooks": ' > "$SETTINGS"
before=$(config_fingerprint)
run_installer uninstall
if [ "$code" -ne 0 ] && is_one_refusal_line && [ "$(config_fingerprint)" = "$before" ] && [ -f "$CONFIG/hooks/keep-warm.sh" ]; then
    pass "$name"
else
    fail "$name" "code=$code err=$err"
fi

name='test_usage_when_the_mode_is_unknown_should_fail'
fresh_config c18
run_installer reinstall
if [ "$code" -eq 1 ] && [ -n "$err" ] && [ ! -e "$CONFIG" ]; then pass "$name"; else fail "$name" "code=$code err=$err"; fi

# --- end to end: the registered command, run the way Claude Code runs it ---------------
name='test_registered_stop_command_in_a_project_without_its_own_hook_should_ping'
fresh_config c15
run_installer install
mkdir -p "$TMP/c15/project"
run_registered_stop "$TMP/c15/project" e2e1
if is_ping; then pass "$name"; else fail "$name" "code=$code out=$out err=$err"; fi

name='test_registered_stop_command_in_a_project_with_its_own_hook_should_do_nothing'
fresh_config c15b
run_installer install
mkdir -p "$TMP/c15b/project/.claude"
cp "$PROJECT_SETTINGS" "$TMP/c15b/project/.claude/settings.json"
run_registered_stop "$TMP/c15b/project" e2e2
if [ "$code" -eq 0 ] && [ -z "$out$err" ] && [ "$elapsed" -le 1 ] && [ ! -e "$TMP/state/claude-keep-warm-e2e2" ]; then
    pass "$name"
else
    fail "$name" "code=$code elapsed=$elapsed err=$err"
fi

# In the home directory the project settings ARE the user settings, which hold
# only the machine-wide registrations — those must not read as the project's own.
name='test_registered_stop_command_in_the_home_directory_should_ping'
fresh_config c15c "$HOME/.claude"
run_installer install
run_registered_stop "$HOME" e2e3
if is_ping; then pass "$name"; else fail "$name" "code=$code out=$out err=$err"; fi

name='test_install_when_config_dir_has_a_space_in_its_path_should_still_work'
fresh_config c16 "$TMP/c16/my config"
run_installer install
mkdir -p "$TMP/c16/project"
run_registered_stop "$TMP/c16/project" e2e4
if is_ping && cmp -s "$HOOK_SOURCE" "$CONFIG/hooks/keep-warm.sh"; then pass "$name"; else fail "$name" "code=$code out=$out err=$err"; fi

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
