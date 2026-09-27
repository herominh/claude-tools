#!/usr/bin/env bash
#
# Installs the keep-warm hook for EVERY Claude Code session on this machine, in
# any project.
#
#   keep-warm/install.sh install     copy the hook and the /m-keep-warm skill
#                                    into the Claude config dir and register
#                                    the hook in its settings.json; re-run it
#                                    to refresh the copies after the hook
#                                    changes
#   keep-warm/install.sh uninstall   remove the registrations and both copies
#
# Config dir: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}. Install writes
# <config>/hooks/keep-warm.sh, <config>/skills/m-keep-warm/SKILL.md and the
# registrations in <config>/settings.json, first saving that file as
# settings.json.keep-warm-backup while it holds none of them. The registrations
# are the handlers in registrations.json — same events, matchers and fields —
# with the command replaced by
#   bash "<config>/hooks/keep-warm.sh" --machine-wide
# (the flag stands the copy down in a project that registers its own hook).
# Every other setting stays as it was; every file is replaced by
# write-then-rename, so a wait running from the old hook copy keeps its file.
#
# Install refuses, changing nothing, without jq; on a Claude Code older than
# keep-warm.sh's MIN_CLAUDE_VERSION; on a config dir path that cannot sit inside
# a double-quoted shell word; and on a settings.json that is a symlink or not a
# JSON object with array-valued hook events.
#
# Exit codes: 0 done (or nothing to uninstall), 1 refused or failed. Fixture
# tests: bash keep-warm/tests/install.test.sh

set -u

readonly PROGRAM='keep-warm-install'
readonly HOOK_MODE=755
readonly SKILL_MODE=644
readonly BACKUP_SUFFIX='.keep-warm-backup'
# registrations.json holds the handlers as a project would register them; their
# command ends in this path and is replaced on install.
readonly PROJECT_HOOK_SUFFIX='/keep-warm.sh'
readonly README_SECTION='README.md, "keep-warm"'

# jq definitions shared by both modes. `ours`: a handler running the machine-
# wide copy ($copy). `strip`: drops those handlers, then the matcher groups and
# events that held nothing else, then "hooks" itself once it is empty — and
# touches nothing that held none of ours. `installed`: any handler is ours.
readonly JQ_DEFS='
def ours: type == "object" and (.command | type) == "string" and (.command | contains($copy));
def strip_group:
  if type == "object" and (.hooks | type) == "array" and any(.hooks[]; ours)
  then .hooks |= map(select(ours | not)) | select((.hooks | length) > 0)
  else . end;
def strip:
  if (.hooks | type) == "object" and (.hooks | length) > 0
  then .hooks |= with_entries(.value as $groups
         | .value |= [.[] | strip_group]
         | select((.value | length) > 0 or ($groups | length) == 0))
       | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end;
def installed: [(.hooks // {})[][]? | objects | .hooks[]?] | any(ours);
'

# The keep-warm handlers of registrations.json as [{event, group}]: each group keeps
# its matcher and holds the handler with only the command replaced.
readonly JQ_DERIVE='
[ (.hooks // {}) | to_entries[] | .key as $event
  | .value[]? | objects | . as $group
  | .hooks[]? | objects
  | select((.command | type) == "string" and (.command | endswith($suffix)))
  | { event: $event,
      group: ((if ($group | has("matcher")) then {matcher: $group.matcher} else {} end)
              + {hooks: [. + {command: $command}]}) } ]'

settings_tmp=''
hook_tmp=''
skill_tmp=''
backup_tmp=''
created_dirs=()
# Once set, a failure has already changed something: no rollback of the
# directories, and the message says the result is partial.
committed=0

refuse() {
    printf '%s: %s. Nothing was changed.\n' "$PROGRAM" "$1" >&2
    exit 1
}

incomplete() {
    printf '%s: %s. The change is incomplete; fix the cause and run it again.\n' "$PROGRAM" "$1" >&2
    exit 1
}

usage() {
    printf 'usage: %s install | uninstall\n' "$0" >&2
    exit 1
}

# Removes the temp files left by a failure and, before the first real change,
# the directories this run created.
clean_up() {
    local temp index
    for temp in "$settings_tmp" "$hook_tmp" "$skill_tmp" "$backup_tmp"; do
        if [ -n "$temp" ]; then rm -f "$temp"; fi
    done
    [ "$committed" -eq 0 ] || return 0
    index=${#created_dirs[@]}
    while [ "$index" -gt 0 ]; do
        index=$(( index - 1 ))
        rmdir "${created_dirs[$index]}" 2>/dev/null
    done
    return 0
}
trap clean_up EXIT

# mkdir that remembers what it created, for clean_up.
make_dir() {
    [ -d "$1" ] && return 0
    mkdir -p "$1" || return 1
    created_dirs+=("$1")
}

# version_at_least <x.y.z> <x.y.z> — the same comparison as keep-warm.sh.
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

require_jq() {
    command -v jq >/dev/null 2>&1 || refuse "$1 needs jq (brew install jq / apt install jq)"
}

# Refuses unless settings.json is absent, or a regular file holding one JSON
# object whose "hooks", when present, maps every event to an array.
check_settings() {
    [ -e "$settings" ] || [ -L "$settings" ] || return 0
    [ -L "$settings" ] && refuse "$settings is a symlink, which this script will not replace — edit the keep-warm registrations in it by hand ($README_SECTION)"
    [ -f "$settings" ] || refuse "$settings is not a regular file"
    [ -r "$settings" ] || refuse "cannot read $settings"
    jq -s 'length' "$settings" >/dev/null 2>&1 || refuse "$settings is not valid JSON; fix it first"
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$settings" >/dev/null 2>&1 \
        || refuse "$settings must hold a single JSON object"
    jq -e '(has("hooks") | not) or ((.hooks | type) == "object" and all(.hooks[]; type == "array"))' "$settings" >/dev/null 2>&1 \
        || refuse "\"hooks\" in $settings must be an object whose every event holds an array"
}

# True when settings.json registers the machine-wide copy.
registrations_present() {
    [ -f "$settings" ] && jq -e --arg copy "$hook_copy" "$JQ_DEFS installed" "$settings" >/dev/null 2>&1
}

# stage_settings <jq filter> — settings.json run through the filter, written to
# a temp file beside it that carries its permission bits, and checked.
stage_settings() {
    settings_tmp=$(mktemp "$config_dir/.settings.json.XXXXXX") || return 1
    if [ -f "$settings" ]; then
        cp -p "$settings" "$settings_tmp" || return 1
        jq --arg copy "$hook_copy" --argjson regs "$registrations" "$JQ_DEFS $1" "$settings" > "$settings_tmp" || return 1
    else
        printf '{}' | jq --arg copy "$hook_copy" --argjson regs "$registrations" "$JQ_DEFS $1" > "$settings_tmp" || return 1
    fi
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$settings_tmp" >/dev/null 2>&1
}

# stage_copy <source> <destination> <mode> — prints a temp file beside the
# destination holding the source's bytes.
stage_copy() {
    local temp
    temp=$(mktemp "${2%/*}/.${2##*/}.XXXXXX") || return 1
    printf '%s' "$temp"
    cp "$1" "$temp" && chmod "$3" "$temp"
}

run_install() {
    local source_file
    for source_file in "$hook_source" "$skill_source" "$settings_source"; do
        [ -f "$source_file" ] || refuse "$source_file is missing — run this script from a claude-tools checkout"
    done
    require_jq install

    local min_version found why_version
    min_version=$(sed -n "s/^readonly MIN_CLAUDE_VERSION='\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)'.*/\1/p" "$hook_source" | head -n 1)
    [ -n "$min_version" ] || refuse "could not read MIN_CLAUDE_VERSION from $hook_source"
    why_version='an older Claude Code skips a settings file with unknown hook fields ENTIRELY (permissions and deny rules included) and could run the wait in the foreground'
    found=$(claude --version 2>/dev/null | head -n 1 | grep -o -E '^[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$found" ] || refuse "cannot read the Claude Code version from claude --version; keep-warm needs $min_version or newer — $why_version"
    version_at_least "$found" "$min_version" \
        || refuse "Claude Code $found is older than $min_version — $why_version; run claude update first"

    case "$config_dir" in
        /*) ;;
        *) refuse "the config dir \"$config_dir\" is not an absolute path" ;;
    esac
    case "$config_dir" in
        *'"'* | *'$'* | *'`'* | *'\'* | *$'\n'*)
            refuse "the config dir path $config_dir holds a \", \$, backtick, backslash or newline, and it has to sit inside a double-quoted command in settings.json"
            ;;
    esac
    check_settings

    registrations=$(jq -c --arg suffix "$PROJECT_HOOK_SUFFIX" --arg command "$registered_command" "$JQ_DERIVE" "$settings_source" 2>/dev/null) \
        || refuse "could not read the keep-warm registrations from $settings_source"
    [ "$(printf '%s' "$registrations" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null \
        || refuse "$settings_source registers no keep-warm hook to copy"

    local backed_up=0
    make_dir "$config_dir" && make_dir "$config_dir/hooks" && make_dir "$config_dir/skills" \
        && make_dir "$config_dir/skills/m-keep-warm" || refuse "could not create the directories under $config_dir"
    stage_settings 'strip | reduce $regs[] as $r (.; .hooks[$r.event] += [$r.group])' \
        || refuse "could not build the new $settings"
    hook_tmp=$(stage_copy "$hook_source" "$hook_copy" "$HOOK_MODE") || refuse "could not write a copy of the hook under $config_dir/hooks"
    skill_tmp=$(stage_copy "$skill_source" "$skill_copy" "$SKILL_MODE") \
        || refuse "could not write a copy of the skill under $config_dir/skills/m-keep-warm"
    if [ -f "$settings" ] && ! registrations_present; then
        backup_tmp=$(mktemp "$config_dir/.settings.json$BACKUP_SUFFIX.XXXXXX") && cp -p "$settings" "$backup_tmp" \
            || refuse "could not back up $settings"
        mv -f "$backup_tmp" "$backup" || refuse "could not write $backup"
        backup_tmp=''
        backed_up=1
    fi

    # The copies land before the registrations that run them.
    committed=1
    mv -f "$hook_tmp" "$hook_copy" || incomplete "could not replace $hook_copy"
    hook_tmp=''
    mv -f "$skill_tmp" "$skill_copy" || incomplete "could not replace $skill_copy"
    skill_tmp=''
    mv -f "$settings_tmp" "$settings" || incomplete "could not replace $settings"
    settings_tmp=''

    local events
    events=$(printf '%s' "$registrations" | jq -r '[.[].event] | join(", ")')
    printf 'keep-warm: installed for every Claude Code session on this machine\n'
    printf '  hook      %s\n' "$hook_copy"
    printf '  skill     %s\n' "$skill_copy"
    printf '  settings  %s — registered on %s\n' "$settings" "$events"
    [ "$backed_up" -eq 1 ] && printf '            (the file as it was before: %s)\n' "$backup"
    printf 'New sessions in every project get the pings. A project that registers its own\n'
    printf 'keep-warm hook in its .claude/settings.json keeps using its own copy.\n'
    printf 'Only the claude on PATH was checked (%s). Every other Claude Code on this\n' "$found"
    printf 'machine — an IDE extension'"'"'s bundled copy, a second install — reads the same\n'
    printf 'settings file and must be %s or newer too: an older one skips the WHOLE\n' "$min_version"
    printf 'file, deny rules included. Update them, or uninstall.\n'
    printf 'Count: /m-keep-warm <0-10|off> in a session, or CLAUDE_KEEP_WARM_PINGS under\n'
    printf '"env" in %s (0 = off).\n' "$settings"
    printf 'Uninstall: bash "%s" uninstall\n' "$script_dir/install.sh"
}

run_uninstall() {
    committed=1
    registrations='[]'
    local removed=''
    if [ -e "$settings" ] || [ -L "$settings" ]; then
        require_jq "uninstall (to edit $settings)"
        check_settings
        if registrations_present; then
            stage_settings 'strip' || refuse "could not build the new $settings"
            mv -f "$settings_tmp" "$settings" || refuse "could not replace $settings"
            settings_tmp=''
            removed="$removed
  the registrations in $settings"
        fi
    fi
    local file
    for file in "$hook_copy" "$skill_copy"; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        rm -f "$file" || incomplete "could not remove $file"
        removed="$removed
  $file"
    done
    rmdir "$config_dir/skills/m-keep-warm" "$config_dir/hooks" 2>/dev/null

    if [ -z "$removed" ]; then
        printf 'keep-warm: nothing to uninstall under %s\n' "$config_dir"
        return 0
    fi
    printf 'keep-warm: removed the machine-wide install:%s\n' "$removed"
    [ -e "$backup" ] && printf 'The settings from before the first install stay in %s.\n' "$backup"
    return 0
}

[ "$#" -eq 1 ] || usage
case "$1" in
    install|uninstall) ;;
    *) usage ;;
esac

script_dir=$(cd "$(dirname "$0")" && pwd) || refuse "cannot locate this script's directory"
hook_source="$script_dir/keep-warm.sh"
skill_source="$script_dir/SKILL.md"
settings_source="$script_dir/registrations.json"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    config_dir=$CLAUDE_CONFIG_DIR
elif [ -n "${HOME:-}" ]; then
    config_dir="$HOME/.claude"
else
    refuse "neither CLAUDE_CONFIG_DIR nor HOME is set, so the Claude config dir is unknown"
fi
# One spelling of the path, so install and uninstall match the same commands.
while :; do
    case "$config_dir" in
        ?*/) config_dir=${config_dir%/} ;;
        *) break ;;
    esac
done
hook_copy="$config_dir/hooks/keep-warm.sh"
skill_copy="$config_dir/skills/m-keep-warm/SKILL.md"
settings="$config_dir/settings.json"
backup="$settings$BACKUP_SUFFIX"
registered_command="bash \"$hook_copy\" --machine-wide"
registrations='[]'

if [ "$1" = install ]; then run_install; else run_uninstall; fi
