#!/usr/bin/env bash
# vim: set ts=2 sw=2 sts=2 et ai tw=80 cc=80 ft=sh :
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
# (jq programs are single-quoted on purpose; tools are called as "tool_$name")
# Keep this file clean: nix develop -c shellcheck agent.sh (also run by
# nix flake check). Never silence a finding without a comment saying why.
# agent.sh — tiny coding agent for OpenCode Go (OpenAI-compatible API)
#
# Usage: agent.sh [-y] [-p | -b] [-i] [-c | -r SESSION_ID] [-h] [-V] [prompt...]
#        agent.sh -l [all]
#        agent.sh --login [copilot]
#   -y       run commands without asking (same as AUTO=1)
#   -p       start in plan mode: read-only commands, no edits (--plan)
#   -b       start in build mode, the default (--build); the last one wins
#   -i       with a prompt: stay in the REPL afterwards instead of exiting
#   -c       continue the most recent session in this directory
#   -r ID    resume a specific session (full id or a unique prefix)
#   -l       list saved sessions for this directory ("all": every directory)
#   -h       show this help (--help works too)
#   -V       show the version (--version works too)
#   prompt   optional first message; the agent answers it and exits (one-shot)
#            unless -i is given (put -- before a prompt that starts with '-')
#
# REPL commands: /help  /about  /model  /compact  /sessions [all]
#                /resume ID  /reset  /auto  /plan  /build  /exit (Ctrl-D)
# /model shows the model, reasoning effort, thinking and temperature;
# /model set temperature 0.1 (or reasoning medium, thinking off) changes one
# for this run, as do the MODEL, REASONING, THINKING and TEMPERATURE
# environment variables. /model list prints the models the endpoint offers
# and /model use picks one by number or name. /context shows the window and
# /context 128000 sets it in tokens at any time (/context compact BYTES sets
# the compaction threshold itself); a session keeps both.
# There are two modes. Build (the default) edits files and runs commands.
# Plan only inspects: it runs read-only commands and refuses everything else.
# A long history is summarized by itself once it reaches COMPACT_AT bytes
# (AUTO_COMPACT=0 turns that off), also in the middle of a long turn;
# /compact does it on demand. The latest exchange is kept as it is when it
# is small enough, and everything before it becomes the summary.
# CONTEXT is the model's window in tokens. When it is set, COMPACT_AT
# defaults to half of it, at 4 bytes per token (CONTEXT=128000 compacts at
# 256000 bytes); unset or 0, it keeps the old 100000 bytes.
# Plugins: *.sh files in $XDG_CONFIG_HOME/agent.sh/plugins (and AGENT_PLUGINS)
# are sourced at startup and add commands, tools, providers and hooks;
# /plugins lists them, AGENT_PLUGINS=none loads none (README, "Plugins").
# The todo tool lets the model keep a plan for a longer task; it is shown as
# it changes, kept with the session and through compaction (/todo shows it).
# rg, fd (fdfind), fzf, ast-grep and tree, when installed, are suggested to
# the model in place of grep -r and find; CLI_HINTS=0 turns that off.
# Settings can come from $XDG_CONFIG_HOME/agent.sh/config.json: "provider",
# "model", "url" and "api_key" (plus reasoning, thinking and temperature).
# Environment variables win over that file.
# Providers: opencode (the default), copilot (GitHub Copilot), openai,
# openrouter and ollama are built in; PROVIDER picks one. A key is read from
# AGENT_API_KEY, else OPENCODE_API_KEY, OPENAI_API_KEY or OPENROUTER_API_KEY
# for that provider, else "api_key" in the config file. The "providers"
# object in config.json sets a model, key or endpoint for each provider and
# can add your own: {"providers": {"work": {"url": "https://host/v1/chat/
# completions", "api_key": "...", "model": "..."}}}. The REPL switches with
# /provider list and /provider use NAME [MODEL]; one provider's key is never
# sent to another. Copilot signs in with GitHub's device flow: run
# agent.sh --login copilot (or /login copilot); the token is kept in
# $XDG_CONFIG_HOME/agent.sh/auth.json, 0600. COPILOT_GITHUB_TOKEN, or the
# token of the Copilot plugin for Vim/Neovim, also works.
# Tools the model has: bash; read, edit and write for files (reading inside
# the workspace needs no approval; edit and write show the change and ask);
# web_search and web_fetch (WEB=0 removes them); explore (below). web_search
# uses Brave (BRAVE_API_KEY), Tavily (TAVILY_API_KEY) or a SearXNG server
# (SEARXNG_URL) when one is set, else DuckDuckGo's HTML page, which needs no
# key but may refuse automated requests. The keys can also be brave_api_key,
# tavily_api_key and searxng_url in config.json.
# Prompt commands: a file commands/NAME.md in a prompt directory is the
# prompt that /NAME sends (commands/review.md makes /review; /help lists
# the ones found). Text after the name replaces {{args}}.
# The model can also start read-only sub-agents with the "explore" tool: each
# is a separate agent.sh that may only inspect, and several run in parallel
# (SUB_MAX at once, 4). SUBAGENTS=0 removes the tool; SUB_TIMEOUT (300) and
# SUB_MAX_STEPS (25) bound one explorer. MAX_STEPS bounds a turn of the main
# agent (0 = no limit): at the limit the model is asked for its answer.
# An AGENTS.md in the working directory is added to the system prompt
# (PROJECT_DOC=0 turns that off).
# The built-in prompts can be replaced by SYSTEM.md, COMPACTION.md, PLAN.md
# and EXPLORE.md (the instructions an explorer gets).
# They are looked up in $PROMPT_DIR (if set), then in
# $XDG_CONFIG_HOME/agent.sh/prompts, then in <install dir>/pro.mpts; a missing
# or blank file keeps the built-in. In a prompt, {{cwd}} is the working
# directory, {{workspace}} the workspace, {{os}} the system and {{date}} today.
# On the first run the config directory is created and the bundled prompts are
# copied into it as NAME.md.example; rename one to NAME.md to override that
# prompt. A fresh session also prints /about.
# The REPL prompt shows the mode, the directory, the git branch ("*" means
# uncommitted changes), the history size against COMPACT_AT and "auto" when
# commands run without asking. PROMPT_PATH_MAX (32) caps the directory,
# PROMPT_GIT=0 and PROMPT_CONTEXT=0 hide those, PROMPT_MODEL=1 adds the
# model; /about shows the full session id.
# Ctrl-C stops the current reply or command without ending the session.
# A command is stopped after CMD_TIMEOUT seconds (600; 0 = never) when the
# "timeout" program is available.
# A command that names a path outside the workspace (the git repository, or
# else the starting directory) needs your approval every time, also under -y.
# OUTSIDE=allow turns the question off and OUTSIDE=deny refuses such commands;
# ALLOW_PATHS=/a:/b adds directories that need no question. So does a
# dangerous command: a program in ASK_CMDS (sudo, dd, reboot, ...), a forced
# push, a hard reset, a download piped into a shell. ASK_CMDS="" empties the
# list. Both read the command text only: a seat belt, not a sandbox.
# jq and curl are required. If one is missing and Nix is installed, it is used
# from the Nix store (fetched if need be); otherwise agent.sh says what to
# install and stops.
# Sessions are saved as JSON in $SESSION_DIR (~/.local/state/agent.sh/sessions).
set -euo pipefail

# Which settings came from the environment: a config file must not override an
# explicit environment variable. ${VAR+x} also distinguishes unset from set
# to the empty string, which matters for REASONING and friends.
MODEL_ENV_SET=${MODEL+1};              MODEL_ENV="${MODEL-}"
PROVIDER_ENV_SET=${PROVIDER+1};        PROVIDER_ENV="${PROVIDER-}"
URL_ENV="${URL-}"
REASONING_ENV_SET=${REASONING+1};      REASONING_ENV="${REASONING-}"
THINKING_ENV_SET=${THINKING+1};        THINKING_ENV="${THINKING-}"
TEMPERATURE_ENV_SET=${TEMPERATURE+1};  TEMPERATURE_ENV="${TEMPERATURE-}"
CONTEXT_ENV_SET=${CONTEXT+1};          COMPACT_AT_ENV_SET=${COMPACT_AT:+1}
AGENT_API_KEY_ENV="${AGENT_API_KEY-}"
# The key stays in this shell only: commands the model runs must not inherit
# it (an "env" would put it in the transcript and send it to the provider).
BRAVE_KEY="${BRAVE_API_KEY-}"
TAVILY_KEY="${TAVILY_API_KEY-}"
# The key each built-in provider takes from the environment (ENVKEY_<name>)
ENVKEY_opencode="${OPENCODE_API_KEY-}"
# shellcheck disable=SC2034  # read indirectly through ENVKEY_<provider>
ENVKEY_openai="${OPENAI_API_KEY-}"
# shellcheck disable=SC2034  # read indirectly through ENVKEY_<provider>
ENVKEY_openrouter="${OPENROUTER_API_KEY-}"
COPILOT_ENV_TOKEN="${COPILOT_GITHUB_TOKEN-}"
unset AGENT_API_KEY OPENCODE_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY \
  COPILOT_GITHUB_TOKEN BRAVE_API_KEY TAVILY_API_KEY
# Sessions, history and temp files hold command output and may hold secrets:
# create them private. Commands the model runs get the original umask back.
ORIG_UMASK=$(umask)
umask 077

MODEL=""                               # default is the provider's
MODEL_GIVEN=0                          # 1 = set by config or environment
PROVIDER="opencode"                    # opencode copilot openai openrouter
                                       # ollama, or one from "providers"
URL=""                                 # default is the provider's endpoint
URL_GIVEN=0                            # 1 = set by config or environment
REASONING=""                           # reasoning effort ("" = omit the field)
REASONING_GIVEN=0                      # default: the provider's (opencode: low)
THINKING=""                            # on/off ("" = server default)
TEMPERATURE=""                         # 0..2 ("" = server default)
AUTO="${AUTO:-0}"                      # 1 = no confirmation prompt
MODE="${MODE:-build}"                  # build (edits) or plan (read-only)
CONTEXT="${CONTEXT:-0}"                # model context window in tokens (0 = unknown)
MAX_OUT="${MAX_OUT:-20000}"            # tool output bytes sent to the model
AUTO_COMPACT="${AUTO_COMPACT:-1}"      # 1 = auto-summarize a long history
COMPACT_AT="${COMPACT_AT:-}"           # history bytes that trigger that; see below
TIMEOUT="${TIMEOUT:-300}"              # seconds of silence before giving up
OUTSIDE="${OUTSIDE:-ask}"              # outside the workspace: ask, allow, deny
# Programs that always need approval, also under -y ("" = none)
ASK_CMDS="${ASK_CMDS-sudo su doas pkexec dd mkfs fdisk parted shutdown reboot \
poweroff halt systemctl nixos-rebuild crontab chown mount umount}"
WORKSPACE="${WORKSPACE:-}"             # default: the git repository, else $PWD
ALLOW_PATHS="${ALLOW_PATHS:-}"         # extra directories, colon-separated
WEB="${WEB:-1}"                        # 1 = offer web_fetch and web_search
WEB_TIMEOUT="${WEB_TIMEOUT:-30}"       # seconds one fetch or search may take
SEARXNG_URL="${SEARXNG_URL:-}"         # a SearXNG server to search with
BRAVE_URL="${BRAVE_URL:-https://api.search.brave.com/res/v1/web/search}"
TAVILY_URL="${TAVILY_URL:-https://api.tavily.com/search}"
DDG_URL="${DDG_URL:-https://html.duckduckgo.com/html/}"
READ_LINES="${READ_LINES:-400}"        # lines the read tool returns at most
SUBAGENTS="${SUBAGENTS:-1}"            # 1 = offer the explore tool (sub-agents)
SUB_MAX="${SUB_MAX:-4}"                # explorers running at the same time
SUB_TIMEOUT="${SUB_TIMEOUT:-300}"      # seconds one explorer may take (0 = no cap)
SUB_MAX_STEPS="${SUB_MAX_STEPS:-25}"   # tool rounds one explorer may use
MAX_STEPS="${MAX_STEPS:-0}"            # tool rounds per turn (0 = no limit)
# Set by a parent agent.sh for the explorers it starts; not a user setting.
SUB="${AGENT_SUB:-0}"
SUB_NAME="${AGENT_SUB_NAME:-explorer}"
unset AGENT_SUB AGENT_SUB_NAME
PROJECT_DOC="${PROJECT_DOC:-1}"        # 1 = add ./AGENTS.md to the system prompt
CMD_TIMEOUT="${CMD_TIMEOUT:-600}"      # seconds one command may run (0 = no cap)
SHOW_REASONING="${SHOW_REASONING:-1}"  # 1 = stream reasoning (dimmed)
PROMPT_PATH_MAX="${PROMPT_PATH_MAX:-32}"  # width of the directory in prompt
PROMPT_GIT="${PROMPT_GIT:-1}"          # 1 = show the git branch
PROMPT_MODEL="${PROMPT_MODEL:-0}"      # 1 = show the model too
PROMPT_CONTEXT="${PROMPT_CONTEXT:-1}"  # 1 = show history size / COMPACT_AT
# A non-numeric setting falls back to its default instead of breaking (( )).
[[ "$PROMPT_PATH_MAX" =~ ^[0-9]+$ ]] || PROMPT_PATH_MAX=32
[[ "$PROMPT_GIT" =~ ^[0-9]+$ ]] || PROMPT_GIT=1
[[ "$PROMPT_MODEL" =~ ^[0-9]+$ ]] || PROMPT_MODEL=0
[[ "$PROMPT_CONTEXT" =~ ^[0-9]+$ ]] || PROMPT_CONTEXT=1
AGENT_HISTFILE="${AGENT_HISTFILE:-$HOME/.agent_sh_history}"
AGENT_HISTORY_MAX="${AGENT_HISTORY_MAX:-1000}"   # lines kept in that file
SESSION_DIR="${SESSION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}\
/agent.sh/sessions}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="${AGENT_CONFIG_DIR:-$XDG_CONFIG_HOME/agent.sh}"
CONFIG_FILE="${AGENT_CONFIG:-$CONFIG_DIR/config.json}"
SYSTEM_CONFIG_FILE="${AGENT_SYSTEM_CONFIG:-/etc/agent.sh/config.json}"
PROMPT_DIR="${PROMPT_DIR-}"            # explicit prompt directory, if set
PROMPT_DIRS=()                         # search path, filled by the function
PROMPT_FROM="built-in"                 # set by read_prompt
INSTALL_DIR=""                         # directory containing agent.sh
CFG_MODEL=""; CFG_URL=""; CFG_API_KEY=""     # top level of the config
CFG_REASONING=""; CFG_REASONING_SET=0
CFG_THINKING=""; CFG_THINKING_SET=0
API_KEY=""                             # set by load_settings
API_KEY_SOURCE=""
PKIND="plain"                          # opencode, copilot, local or plain
URL_FIXED=0                            # 1 = the user chose this endpoint
RESP_MODELS="${AGENT_RESPONSES_MODELS-}"  # models that need /responses
TODOS='[]'                             # the model's todo list (JSON)
# GitHub Copilot: a sign-in token is exchanged for a short-lived session
# token (API_KEY) that expires at COPILOT_EXP (epoch seconds). The client id
# is the public one of the Copilot plugin for Vim/Neovim. The URLs can be
# replaced for testing.
COPILOT_OAUTH=""
COPILOT_EXP=0
COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"
COPILOT_API_URL="${COPILOT_API_URL:-\
https://api.githubcopilot.com/chat/completions}"
COPILOT_TOKEN_URL="${COPILOT_TOKEN_URL:-\
https://api.github.com/copilot_internal/v2/token}"
COPILOT_LOGIN_URL="${COPILOT_LOGIN_URL:-https://github.com}"
COPILOT_EDITOR="${COPILOT_EDITOR:-vscode/1.99.3}"
COPILOT_PLUGIN="${COPILOT_PLUGIN:-copilot-chat/0.26.7}"
CONFIG_LOADED=0

VERSION="0.5.0"
RELEASED="2026-11-13"
AUTHOR="fb87"                                       # see LICENSE

new_id() {
  uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null ||
    echo "bash-agent-$$-$(date +%s)"
}

# The script's own path, with symlinks resolved, so a symlink in ~/.local/bin
# or a Nix wrapper still finds the bundled pro.mpts directory beside it, and
# explorers are started from the real file.
resolve_self() {
  local src="${BASH_SOURCE[0]}" dir
  while [[ -L "$src" ]]; do
    dir=$(cd -P "$(dirname "$src")" 2>/dev/null && pwd) || break
    src=$(readlink "$src" 2>/dev/null) || break
    [[ "$src" == /* ]] || src="$dir/$src"
  done
  dir=$(cd -P "$(dirname "$src")" 2>/dev/null && pwd) || dir="."
  printf '%s/%s' "$dir" "$(basename "$src")"
}

# ----------------------------------------------------------------- plugins

# Plugins are bash files, *.sh in $CONFIG_DIR/plugins (and the files or
# directories of AGENT_PLUGINS, separated by colons; AGENT_PLUGINS=none loads
# none).
# Each is sourced into this shell at startup, so it is trusted code with the
# reach of the script itself. At load time it only registers what it adds:
#
#   agent_command NAME "help"       /NAME [args] -> cmd_NAME "args"; a
#                                   command may set AGENT_PROMPT to send it
#   agent_tool NAME "what it does" 'PARAMS' [ro]
#                                   a tool for the model -> tool_NAME 'JSON
#                                   arguments', its stdout is the result;
#                                   PARAMS is a JSON schema object, "ro" marks
#                                   it usable in plan mode
#   agent_provider NAME             provider_NAME sets P_URL, P_MODEL and
#                                   optionally P_REASONING, P_KIND, P_KEY;
#                                   provider_NAME_headers prints extra
#                                   headers, provider_NAME_prepare runs before
#                                   each request (non-zero = fail, PLUGIN_ERR)
#   agent_hook EVENT FUNC           start, turn_start TEXT, turn_end OK,
#                                   exit, and tool_call NAME ARGS (non-zero
#                                   blocks the call; stdout is the reason)
#
# Names are lower case letters, digits and _. A built-in name cannot be taken.
PLUGIN_FILES=""
PLUGIN_COMMANDS=" "
PLUGIN_COMMAND_HELP=""
PLUGIN_TOOLS_JSON="[]"
PLUGIN_TOOLS_RO=" "
PLUGIN_PROVIDERS=" "
PLUGIN_HOOKS=" "
PLUGIN_CURRENT=""
PLUGIN_ERR=""
AGENT_PROMPT=""
PLUGIN_BUILTIN_COMMANDS=" help about model provider login compact context"
PLUGIN_BUILTIN_COMMANDS+=" sessions resume reset auto plan build exit quit"
PLUGIN_BUILTIN_COMMANDS+=" plugins todo "
PLUGIN_BUILTIN_TOOLS=" bash read write edit web_search web_fetch explore todo "
PLUGIN_BUILTIN_PROVIDERS=" opencode opencode-go copilot github-copilot openai"
PLUGIN_BUILTIN_PROVIDERS+=" openrouter ollama "
PLUGIN_EVENTS=" start turn_start turn_end exit tool_call "

plugin_warn() {
  printf 'agent.sh: plugin %s: %s\n' "${PLUGIN_CURRENT:-?}" "$*" >&2
}

# True if $1 may name something a plugin adds
plugin_name_ok() {
  if [[ ! "$1" =~ ^[a-z][a-z0-9_]*$ ]]; then
    plugin_warn "'$1' is not a usable name (lower case letters, digits, _)"
    return 1
  fi
}

agent_command() {
  local name="${1:-}"
  plugin_name_ok "$name" || return 0
  if [[ "$PLUGIN_BUILTIN_COMMANDS" == *" $name "* ]]; then
    plugin_warn "/$name is a built-in command"; return 0
  fi
  if [[ "$PLUGIN_COMMANDS" == *" $name "* ]]; then
    plugin_warn "/$name is already taken by another plugin"; return 0
  fi
  PLUGIN_COMMANDS+="$name "
  PLUGIN_COMMAND_HELP+="$name"$'\x1f'"${2:-}"$'\x1f'"$PLUGIN_CURRENT"$'\n'
}

agent_tool() {
  local name="${1:-}" desc="${2:-}" params="${3:-}"
  plugin_name_ok "$name" || return 0
  if [[ "$PLUGIN_BUILTIN_TOOLS" == *" $name "* ]]; then
    plugin_warn "$name is a built-in tool"; return 0
  fi
  if [[ ", $PLUGIN_TOOLS_NAMES, " == *", $name, "* ]]; then
    plugin_warn "tool $name is already taken by another plugin"; return 0
  fi
  [[ -n "$params" ]] || params='{"type": "object", "properties": {}}'
  if ! jq -e 'type == "object"' <<<"$params" >/dev/null 2>&1; then
    plugin_warn "the parameters of tool $name are not a JSON object"; return 0
  fi
  PLUGIN_TOOLS_JSON=$(jq -c --arg n "$name" --arg d "$desc" \
    --argjson p "$params" \
    '. + [{type: "function",
           function: {name: $n, description: $d, parameters: $p}}]' \
    <<<"$PLUGIN_TOOLS_JSON")
  PLUGIN_TOOLS_NAMES+="${PLUGIN_TOOLS_NAMES:+, }$name"
  if [[ "${4:-}" == ro ]]; then PLUGIN_TOOLS_RO+="$name "; fi
}
PLUGIN_TOOLS_NAMES=""

agent_provider() {
  local name="${1:-}"
  plugin_name_ok "$name" || return 0
  if [[ "$PLUGIN_BUILTIN_PROVIDERS" == *" $name "* ]]; then
    plugin_warn "$name is a built-in provider"; return 0
  fi
  if [[ "$PLUGIN_PROVIDERS" == *" $name "* ]]; then
    plugin_warn "provider $name is already taken by another plugin"; return 0
  fi
  PLUGIN_PROVIDERS+="$name "
}

agent_hook() {
  local event="${1:-}" fn="${2:-}"
  if [[ "$PLUGIN_EVENTS" != *" $event "* ]]; then
    plugin_warn "unknown event '$event' (${PLUGIN_EVENTS# })"; return 0
  fi
  if [[ ! "$fn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    plugin_warn "hook $event needs a function name"; return 0
  fi
  PLUGIN_HOOKS+="$event:$fn "
}

# True if nobody but the user (or root) could have written plugin file $1 or
# can replace it; otherwise says why in PLUGIN_ERR
plugin_file_safe() {
  local f="$1" d
  d=$(dirname "$f")
  PLUGIN_ERR=""
  if [[ -n "$(find "$f" -maxdepth 0 -perm -002 2>/dev/null)" ]]; then
    PLUGIN_ERR="anybody can write to it"
  elif [[ -n "$(find "$d" -maxdepth 0 -perm -002 2>/dev/null)" ]]; then
    PLUGIN_ERR="anybody can write to its directory"
  elif [[ ! -O "$f" && -z "$(find "$f" -maxdepth 0 -user 0 2>/dev/null)" ]]
  then
    PLUGIN_ERR="it belongs to another user"
  fi
  [[ -z "$PLUGIN_ERR" ]]
}

# Runs a plugin function in this shell. A plugin is not written for
# "set -u": an unset variable there must not end the whole session.
plugin_call() {
  local rc=0
  set +u
  "$@" || rc=$?
  set -u
  return "$rc"
}

# Sources the plugin files. One that fails to load is reported and
# skipped, not fatal; one anybody can write to is not loaded at all.
load_plugins() {
  local spec f g list="" IFS_SAVE="$IFS"
  [[ "${AGENT_PLUGINS-}" == none ]] && return 0
  if [[ -d "$CONFIG_DIR/plugins" ]]; then
    for g in "$CONFIG_DIR/plugins"/*.sh; do
      [[ -f "$g" ]] && list+="$g"$'\n'
    done
  fi
  if [[ -n "${AGENT_PLUGINS-}" ]]; then
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      if [[ -d "$spec" ]]; then
        for g in "$spec"/*.sh; do
          [[ -f "$g" ]] && list+="$g"$'\n'
        done
      elif [[ -f "$spec" ]]; then list+="$spec"$'\n'
      else printf 'agent.sh: AGENT_PLUGINS: %s does not exist\n' "$spec" >&2
      fi
    done < <(printf '%s\n' "$AGENT_PLUGINS" | tr ':' '\n')
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == /* ]] || f="./$f"
    # Code that another user could have written or can replace is not run
    if ! plugin_file_safe "$f"; then
      printf 'agent.sh: not loading %s: %s\n' "$f" "$PLUGIN_ERR" >&2
      continue
    fi
    PLUGIN_CURRENT="${f##*/}"
    PLUGIN_FILES+="$f"$'\n'
    set +u
    # shellcheck disable=SC1090  # plugin path is only known at run time
    if ! . "$f"; then plugin_warn "stopped with an error while loading"; fi
    set -u
  done <<<"$list"
  PLUGIN_CURRENT=""
  IFS="$IFS_SAVE"
}

# Runs the hooks of event $1 with the other arguments; never fatal. Not in
# an explorer: its parent runs them.
plugin_hooks() {
  local event="$1" h
  shift
  (( SUB )) && return 0
  [[ "$PLUGIN_HOOKS" == *" $event:"* ]] || return 0
  for h in $PLUGIN_HOOKS; do
    [[ "$h" == "$event:"* ]] || continue
    if declare -F "${h#*:}" >/dev/null; then
      plugin_call "${h#*:}" "$@" || true
    else
      printf 'agent.sh: hook %s: no function %s\n' "$event" "${h#*:}" >&2
    fi
  done
}

# The tool_call hooks: prints the reason and fails if one blocks the call
plugin_tool_allowed() {
  local h out
  [[ "$PLUGIN_HOOKS" == *" tool_call:"* ]] || return 0
  for h in $PLUGIN_HOOKS; do
    [[ "$h" == tool_call:* ]] || continue
    declare -F "${h#*:}" >/dev/null || continue
    if ! out=$(set +u; "${h#*:}" "$1" "$2" 2>&9); then
      printf '%s' "$out"
      return 1
    fi
  done
  return 0
}

# Runs plugin tool $1 with the arguments object $2: its stdout is the
# result. Plan mode only allows the ones registered as read-only.
plugin_tool_run() {
  local name="$1" args="$2" out rc=0
  if [[ "$MODE" == plan && "$PLUGIN_TOOLS_RO" != *" $name "* ]]; then
    TOOL_OUT="Plan mode: $name is not read-only, so it was not run."
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return 0
  fi
  if ! declare -F "tool_$name" >/dev/null; then
    TOOL_OUT="Error: the plugin did not define tool_$name."
    return 0
  fi
  tool_line "$name $args"
  # Like a command: a tool that may change things is asked about first
  if [[ "$PLUGIN_TOOLS_RO" != *" $name "* ]]; then
    confirm "Run it?" "to run the $name tool" \
      "run with -y to approve up front" || return 0
  fi
  out=$(set +u; "tool_$name" "$args" 2>&9) || rc=$?
  if (( ${#out} > MAX_OUT )); then
    out="${out:0:MAX_OUT}"$'\n'"...[output truncated]..."
  fi
  if (( rc )); then out+=$'\n'"[exit code $rc]"; fi
  TOOL_OUT="$out"
}

# True if $1 is a command a plugin added; sets PLUGIN_CMD and PLUGIN_ARGS
plugin_command_match() {
  [[ "$PLUGIN_COMMANDS" != " " ]] || return 1
  [[ "$1" =~ ^/([a-z][a-z0-9_]*)([[:space:]]+(.*))?$ ]] || return 1
  [[ "$PLUGIN_COMMANDS" == *" ${BASH_REMATCH[1]} "* ]] || return 1
  PLUGIN_CMD="${BASH_REMATCH[1]}"; PLUGIN_ARGS="${BASH_REMATCH[3]:-}"
}

# /plugins: what is loaded and what each file added
plugin_info() {
  local f n t line h
  if [[ -z "$PLUGIN_FILES" ]]; then
    printf 'No plugins. Put *.sh files in %s/plugins (see the README).\n' \
      "$CONFIG_DIR"
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    printf '  %s\n' "$f"
  done <<<"$PLUGIN_FILES"
  [[ "$PLUGIN_COMMANDS" == " " ]] || printf '  commands   %s\n' \
    "$(sed 's/^ //; s/ $//; s/ /, \//g; s/^/\//' <<<"$PLUGIN_COMMANDS")"
  [[ -z "$PLUGIN_TOOLS_NAMES" ]] ||
    printf '  tools      %s\n' "$PLUGIN_TOOLS_NAMES"
  [[ "$PLUGIN_PROVIDERS" == " " ]] || printf '  providers  %s\n' \
    "$(sed 's/^ //; s/ $//; s/ /, /g' <<<"$PLUGIN_PROVIDERS")"
  [[ "$PLUGIN_HOOKS" == " " ]] || printf '  hooks      %s\n' \
    "$(sed 's/^ //; s/ $//; s/ /, /g' <<<"$PLUGIN_HOOKS")"
}

# ------------------------------------------------------------------ providers

# The built-in providers. Sets P_NAME (the canonical name), P_KIND (opencode,
# copilot, local = no key needed, plain), P_URL, P_MODEL and P_REASONING (the
# defaults); fails for a name that is not built in. The models are only
# starting points: /model list shows what the endpoint really offers.
provider_spec() {
  P_NAME="$1"; P_KIND=plain; P_URL=""; P_MODEL=""; P_REASONING=""; P_KEY=""
  case "$1" in
    opencode|opencode-go)
      P_NAME=opencode; P_KIND=opencode; P_REASONING=low
      P_URL='https://opencode.ai/zen/go/v1/chat/completions'
      P_MODEL="deepseek-v4.1-flash" ;;
    copilot|github-copilot)
      P_NAME=copilot; P_KIND=copilot
      P_URL="$COPILOT_API_URL"; P_MODEL="gpt-4.1" ;;
    openai)
      P_URL='https://api.openai.com/v1/chat/completions'
      P_MODEL="gpt-4.1-mini" ;;
    openrouter)
      P_URL='https://openrouter.ai/api/v1/chat/completions'
      P_MODEL="openai/gpt-4.1-mini" ;;
    ollama)
      P_KIND=local
      P_URL='http://localhost:11434/v1/chat/completions'
      P_MODEL="qwen2.5-coder:7b" ;;
    *) # one a plugin added: its function says what it is
       if [[ "$PLUGIN_PROVIDERS" == *" $1 "* ]] && declare -F "provider_$1" \
            >/dev/null; then
         plugin_call "provider_$1" || true
         return 0
       fi
       return 1 ;;
  esac
}

# What the "providers" object of the config files says about provider $1:
# url, model, api_key and reasoning, separated by \x1f (the user's file wins
# over the system one, field by field).
cfg_provider() {
  local f v url="" model="" key="" reasoning="" a b c d
  for f in "$SYSTEM_CONFIG_FILE" "$CONFIG_FILE"; do
    [[ -f "$f" ]] || continue
    v=$(jq -r --arg p "$1" '
      (.providers // {}) | (if type == "object" then .[$p] else null end)
      | if type == "object" then
          [.url, .model, .api_key, .reasoning]
          | map(if type == "string" then . else "" end) | join("\u001f")
        else "" end' "$f" 2>/dev/null) || v=""
    IFS=$'\x1f' read -r a b c d <<<"$v" || true
    if [[ -n "$a" ]]; then url="$a"; fi
    if [[ -n "$b" ]]; then model="$b"; fi
    if [[ -n "$c" ]]; then key="$c"; fi
    if [[ -n "$d" ]]; then reasoning="$d"; fi
  done
  printf '%s\x1f%s\x1f%s\x1f%s' "$url" "$model" "$key" "$reasoning"
}

# The names under "providers" in the config files, one per line
cfg_provider_names() {
  local f
  for f in "$SYSTEM_CONFIG_FILE" "$CONFIG_FILE"; do
    [[ -f "$f" ]] || continue
    jq -r '(.providers // {})
           | if type == "object" then keys[] else empty end' \
      "$f" 2>/dev/null || true
  done
}

# The built-in name a provider name stands for (opencode-go -> opencode)
canon_provider() {
  if provider_spec "$1"; then printf '%s' "$P_NAME"; else printf '%s' "$1"; fi
}

upper() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }

# The key the environment gave a built-in provider ("" if none)
env_key() {
  local var="ENVKEY_${1//[^A-Za-z0-9]/_}"
  printf '%s' "${!var-}"
}

# The GitHub sign-in token for Copilot: from COPILOT_GITHUB_TOKEN, from our
# own auth.json, or from the Copilot plugin for Vim/Neovim. Sets R_OAUTH and
# R_KEY_SRC; fails if there is none.
copilot_find_token() {
  local f t
  R_OAUTH=""
  if [[ -n "$COPILOT_ENV_TOKEN" ]]; then
    R_OAUTH="$COPILOT_ENV_TOKEN"; R_KEY_SRC="env COPILOT_GITHUB_TOKEN"
    return 0
  fi
  f="$CONFIG_DIR/auth.json"
  t=$(jq -r '.copilot.oauth_token // empty' "$f" 2>/dev/null) || t=""
  if [[ -n "$t" ]]; then R_OAUTH="$t"; R_KEY_SRC="$f"; return 0; fi
  for f in "$XDG_CONFIG_HOME/github-copilot/apps.json" \
           "$XDG_CONFIG_HOME/github-copilot/hosts.json"; do
    [[ -f "$f" ]] || continue
    t=$(jq -r '[.[]? | objects | .oauth_token? // empty] | first // empty' \
          "$f" 2>/dev/null) || t=""
    if [[ -n "$t" ]]; then R_OAUTH="$t"; R_KEY_SRC="$f"; return 0; fi
  done
  return 1
}

# Works out everything that belongs to provider $1 into R_* variables and
# leaves the live settings alone, so a failed switch changes nothing. $2 is 1
# at startup, when the top-level "url", "model", "api_key" of the config and
# the environment (URL, MODEL, REASONING, AGENT_API_KEY) belong to this
# provider; 0 when switching, when only what is specific to the provider
# counts: its environment variable, its entry in "providers", the defaults.
# The key of one provider is therefore never sent to another.
resolve_provider() {
  local name="$1" initial="$2" cp_url cp_model cp_key cp_reasoning builtin=1
  R_ERR=""; R_OAUTH=""; R_KEY=""; R_KEY_SRC=""; R_FIXED=0
  if ! provider_spec "$name"; then
    builtin=0
    P_NAME="$name"; P_KIND=plain; P_URL=""; P_MODEL=""; P_REASONING=""
  fi
  IFS=$'\x1f' read -r cp_url cp_model cp_key cp_reasoning \
    < <(cfg_provider "$name") || true
  R_NAME="$P_NAME"; R_KIND="$P_KIND"

  R_URL="$P_URL"
  if [[ -n "$cp_url" ]]; then R_URL="$cp_url"; R_FIXED=1; fi
  if (( initial && URL_GIVEN )); then R_URL="$URL"; R_FIXED=1; fi
  if [[ -z "$R_URL" ]]; then
    R_ERR="unknown provider \"$name\"; add it under \"providers\" in"
    R_ERR+=" $CONFIG_FILE with a \"url\" (/provider list shows the others)"
    return 1
  fi

  if (( initial && MODEL_GIVEN )); then R_MODEL="$MODEL"
  elif [[ -n "$cp_model" ]]; then R_MODEL="$cp_model"
  else R_MODEL="$P_MODEL"; fi
  if [[ -z "$R_MODEL" ]]; then
    R_ERR="provider \"$name\" has no default model; set \"model\" under"
    R_ERR+=" providers.$name in $CONFIG_FILE"
    return 1
  fi

  if (( initial && REASONING_GIVEN )); then R_REASONING="$REASONING"
  elif [[ -n "$cp_reasoning" ]]; then
    case "$cp_reasoning" in
      default|off|none) R_REASONING="" ;;
      minimal|low|medium|high) R_REASONING="$cp_reasoning" ;;
      *) R_ERR="reasoning of provider \"$name\" must be minimal, low,"
         R_ERR+=" medium, high or default"
         return 1 ;;
    esac
  else R_REASONING="$P_REASONING"; fi

  if [[ "$R_KIND" == copilot ]]; then
    if (( SUB )); then            # an explorer is handed its parent's token
      R_KEY="$AGENT_API_KEY_ENV"; R_KEY_SRC="parent agent"
      if [[ -z "$R_KEY" ]]; then R_ERR="no Copilot token from the parent"
        return 1; fi
    elif (( initial )) && [[ -n "$AGENT_API_KEY_ENV" ]]; then
      R_OAUTH="$AGENT_API_KEY_ENV"; R_KEY_SRC="env AGENT_API_KEY"
    elif ! copilot_find_token; then
      R_ERR="not signed in to GitHub Copilot: run agent.sh --login copilot"
      R_ERR+=" (or /login copilot)"
      return 1
    fi
    return 0
  fi
  if (( initial )) && [[ -n "$AGENT_API_KEY_ENV" ]]; then
    R_KEY="$AGENT_API_KEY_ENV"; R_KEY_SRC="env AGENT_API_KEY"
  elif [[ -n "$(env_key "$name")" ]]; then
    R_KEY="$(env_key "$name")"; R_KEY_SRC="env $(upper "$name")_API_KEY"
  elif [[ -n "$cp_key" ]]; then
    R_KEY="$cp_key"; R_KEY_SRC="config providers.$name"
  elif (( builtin )) && [[ -n "${P_KEY:-}" ]]; then
    R_KEY="$P_KEY"; R_KEY_SRC="plugin"
  elif (( initial )) && [[ -n "$API_KEY" ]]; then
    R_KEY="$API_KEY"; R_KEY_SRC="$API_KEY_SOURCE"
  elif (( initial && ! builtin )) && [[ -n "$ENVKEY_opencode" ]]; then
    R_KEY="$ENVKEY_opencode"; R_KEY_SRC="env OPENCODE_API_KEY"
  elif [[ "$R_KIND" == local ]]; then
    R_KEY="none"; R_KEY_SRC="none needed"
  else
    R_ERR="no API key for provider \"$name\": set "
    if (( initial )); then R_ERR+="AGENT_API_KEY or "; fi
    if (( builtin )) && [[ "$PLUGIN_PROVIDERS" != *" $name "* ]]; then
      R_ERR+="$(upper "$name")_API_KEY or "
    fi
    R_ERR+="\"api_key\" in $CONFIG_FILE"
    if (( ! builtin )) || [[ "$PLUGIN_PROVIDERS" == *" $name "* ]]; then
      R_ERR+=" (under providers.$name)"
    fi
    return 1
  fi
  return 0
}

# What a failed reply said, on one line: the "message" of a JSON error, else
# the first bytes of the body
reply_note() {
  [[ -s "$1" ]] || return 0
  jq -r '(.error.message? // .error? // .message? // empty)
         | if type == "string" then . else tojson end' "$1" 2>/dev/null |
    head -c 300 | tr '\n' ' ' | grep . || head -c 300 "$1" | tr '\n' ' '
}

# Makes the result of resolve_provider the live settings
commit_provider() {
  PROVIDER="$R_NAME"; PKIND="$R_KIND"; URL="$R_URL"; URL_FIXED="$R_FIXED"
  MODEL="$R_MODEL"; REASONING="$R_REASONING"
  API_KEY="$R_KEY"; API_KEY_SOURCE="$R_KEY_SRC"
  COPILOT_OAUTH="$R_OAUTH"; COPILOT_EXP=0
  if [[ -n "${TMP:-}" ]]; then rm -f "$TMP/auth"; fi
}

# Writes the header file curl reads (-H @file): the key goes there rather
# than on the command line, where ps would show it.
write_auth() {
  local tmp="$TMP/auth.$$"
  {
    # one line whatever the key holds: a line break would add a header
    printf 'Authorization: Bearer %s\n' "${API_KEY//[$'\r\n']/}"
    if [[ "$PKIND" == copilot ]]; then
      printf 'Copilot-Integration-Id: vscode-chat\n'
      printf 'Editor-Version: %s\n' "$COPILOT_EDITOR"
      printf 'Editor-Plugin-Version: %s\n' "$COPILOT_PLUGIN"
      printf 'User-Agent: GitHubCopilotChat/%s\n' "${COPILOT_PLUGIN#*/}"
    fi
    if [[ "$PLUGIN_PROVIDERS" == *" $PROVIDER "* ]] &&
       declare -F "provider_${PROVIDER}_headers" >/dev/null; then
      plugin_call "provider_${PROVIDER}_headers" | tr -d '\r' || true
    fi
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$TMP/auth" 2>/dev/null || true
}

# Copilot: makes sure API_KEY is a session token with at least $1 seconds
# left (120 by default), exchanging the sign-in token when it is not. Says
# why and fails if GitHub does not give one.
copilot_session() {
  local margin="${1:-120}" now code hdr tok exp api note
  if (( SUB )); then return 0; fi
  now=$(date +%s)
  if [[ -n "$API_KEY" ]] && (( COPILOT_EXP - now > margin )); then
    return 0
  fi
  [[ -d "$TMP" ]] || mkdir -p "$TMP" 2>/dev/null || true
  hdr="$TMP/cp.hdr"
  {
    printf 'Authorization: token %s\n' "$COPILOT_OAUTH"
    printf 'Accept: application/json\n'
    printf 'Editor-Version: %s\n' "$COPILOT_EDITOR"
    printf 'Editor-Plugin-Version: %s\n' "$COPILOT_PLUGIN"
    printf 'User-Agent: GitHubCopilotChat/%s\n' "${COPILOT_PLUGIN#*/}"
  } >"$hdr" 2>/dev/null || true
  code=$(curl -sS --connect-timeout 30 --max-time 60 -H @"$hdr" \
    -o "$TMP/cp.json" -w '%{http_code}' "$COPILOT_TOKEN_URL" \
    2>"$TMP/cp.err") || code=""
  rm -f "$hdr"
  case "$code" in
    2??) ;;
    401|403)
      COPILOT_LAST_ERR="GitHub refused the Copilot sign-in (HTTP $code): run"
      COPILOT_LAST_ERR+=" agent.sh --login copilot again"
      note=$(reply_note "$TMP/cp.json") || note=""
      if [[ -n "$note" ]]; then COPILOT_LAST_ERR+=" [GitHub said: $note]"; fi
      return 1 ;;
    404)
      COPILOT_LAST_ERR="this GitHub account has no Copilot access (HTTP 404)"
      return 1 ;;
    *)
      COPILOT_LAST_ERR="cannot get a Copilot token${code:+ (HTTP $code)}"
      if [[ -s "$TMP/cp.err" ]]; then
        COPILOT_LAST_ERR+=": $(head -c 200 "$TMP/cp.err" | tr '\n' ' ')"
      fi
      note=$(reply_note "$TMP/cp.json") || note=""
      if [[ -n "$note" ]]; then COPILOT_LAST_ERR+=" [GitHub said: $note]"; fi
      return 1 ;;
  esac
  tok=$(jq -r '.token // empty' "$TMP/cp.json" 2>/dev/null) || tok=""
  if [[ -z "$tok" ]]; then
    COPILOT_LAST_ERR="GitHub's reply held no Copilot token"
    return 1
  fi
  exp=$(jq -r '.expires_at // empty | tonumber? // empty' "$TMP/cp.json" \
          2>/dev/null) || exp=""
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=$((now + 1500))
  API_KEY="$tok"; COPILOT_EXP="$exp"
  # The reply names the host to talk to (business and enterprise plans have
  # their own); only a githubcopilot.com host is trusted with the token.
  api=$(jq -r '.endpoints.api // empty' "$TMP/cp.json" 2>/dev/null) || api=""
  if (( ! URL_FIXED )) &&
     [[ "$api" =~ ^https://([A-Za-z0-9-]+\.)*githubcopilot\.com$ ]]; then
    URL="$api/chat/completions"
  fi
  rm -f "$TMP/cp.json" "$TMP/cp.err"
  write_auth
}

# GitHub's device flow: shows a code to enter on github.com, waits for the
# approval and keeps the sign-in token in auth.json (0600).
copilot_login() {
  local body reply code user_code uri interval expires deadline now tok err f
  local -a hdrs=(-H "Accept: application/json"
                 -H "Content-Type: application/json"
                 -H "Editor-Version: $COPILOT_EDITOR"
                 -H "Editor-Plugin-Version: $COPILOT_PLUGIN"
                 -H "User-Agent: GitHubCopilotChat/${COPILOT_PLUGIN#*/}")
  body=$(jq -cn --arg id "$COPILOT_CLIENT_ID" \
           '{client_id: $id, scope: "read:user"}')
  reply=$(curl -sS --connect-timeout 30 --max-time 60 "${hdrs[@]}" \
    -d @- "$COPILOT_LOGIN_URL/login/device/code" 2>&1 <<<"$body") || {
    printf 'agent.sh: cannot reach GitHub: %s\n' "$reply" >&2; return 1; }
  code=$(jq -r '.device_code // empty' <<<"$reply" 2>/dev/null) || code=""
  user_code=$(jq -r '.user_code // empty' <<<"$reply" 2>/dev/null) || true
  uri=$(jq -r '.verification_uri // empty' <<<"$reply" 2>/dev/null) || true
  interval=$(jq -r '.interval // 5' <<<"$reply" 2>/dev/null) || interval=5
  expires=$(jq -r '.expires_in // 900' <<<"$reply" 2>/dev/null) || expires=900
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
  [[ "$expires" =~ ^[0-9]+$ ]] || expires=900
  if [[ -z "$code" || -z "$user_code" ]]; then
    printf 'agent.sh: GitHub did not start a sign-in: %s\n' \
      "$(head -c 200 <<<"$reply")" >&2
    return 1
  fi
  printf 'Open %s and enter the code: %s\n' \
    "${uri:-$COPILOT_LOGIN_URL/login/device}" "$user_code" >&2
  printf 'Waiting for you to approve it (Ctrl-C to cancel)...\n' >&2
  INTERRUPTED=0
  deadline=$(( $(date +%s) + expires ))
  body=$(jq -cn --arg id "$COPILOT_CLIENT_ID" --arg d "$code" \
    '{client_id: $id, device_code: $d,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code"}')
  tok=""
  while now=$(date +%s); (( now < deadline )); do
    sleep "$interval" || true
    if (( ${INTERRUPTED:-0} )); then
      INTERRUPTED=0
      printf 'agent.sh: sign-in cancelled\n' >&2; return 1
    fi
    # on stdin: the device code must not show in the process list
    reply=$(curl -sS --connect-timeout 30 --max-time 60 "${hdrs[@]}" \
      -d @- "$COPILOT_LOGIN_URL/login/oauth/access_token" \
      2>/dev/null <<<"$body") || reply=""
    tok=$(jq -r '.access_token // empty' <<<"$reply" 2>/dev/null) || tok=""
    if [[ -n "$tok" ]]; then break; fi
    err=$(jq -r '.error // empty' <<<"$reply" 2>/dev/null) || err=""
    case "$err" in
      authorization_pending|"") ;;
      slow_down) interval=$((interval + 5)) ;;
      expired_token) break ;;
      access_denied)
        printf 'agent.sh: the sign-in was denied\n' >&2; return 1 ;;
      *) printf 'agent.sh: GitHub said: %s\n' "$err" >&2; return 1 ;;
    esac
  done
  if [[ -z "$tok" ]]; then
    printf 'agent.sh: the code expired before it was approved\n' >&2
    return 1
  fi
  mkdir -p "$CONFIG_DIR" 2>/dev/null && chmod 700 "$CONFIG_DIR" 2>/dev/null ||
    true
  f="$CONFIG_DIR/auth.json"
  (
    umask 077
    TOK="$tok" jq -n --slurpfile old <([[ -f "$f" ]] && cat "$f" || echo '{}') \
      '(($old[0] // {}) | if type == "object" then . else {} end)
       + {copilot: {oauth_token: $ENV.TOK}}' >"$f.new" &&
      mv -f "$f.new" "$f"
  ) || { printf 'agent.sh: cannot write %s\n' "$f" >&2; return 1; }
  chmod 600 "$f" 2>/dev/null || true
  printf 'Signed in to GitHub. The token is kept in %s\n' "$f" >&2
  return 0
}

# /provider: the current provider and where its key came from
provider_info() {
  printf '  %-9s %s\n' provider "$PROVIDER"
  printf '  %-9s %s\n' model "$MODEL"
  printf '  %-9s %s\n' endpoint "$URL"
  printf '  %-9s %s\n' key "${API_KEY_SOURCE:-unknown}"
  echo "Switch with: /provider use <name> [model]   (/provider list)"
}

# /provider list: every provider this run can use, the current one marked
provider_list() {
  local n names="opencode copilot openai openrouter ollama" status seen=" "
  names+="${PLUGIN_PROVIDERS% }"
  local keep_name="$R_NAME"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    names+=" $n"
  done < <(cfg_provider_names)
  for n in $names; do
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    if resolve_provider "$n" 0 2>/dev/null; then
      status="ready, model $R_MODEL"
    else
      status="not ready: $R_ERR"
    fi
    if [[ "$n" == "$PROVIDER" ]]; then
      printf '  \033[1m%-11s *  %s\033[0m\n' "$n" "$status"
    else
      printf '  %-11s    %s\n' "$n" "$status"
    fi
  done
  R_NAME="$keep_name"
  echo "Switch with: /provider use <name> [model]"
}

# /provider use NAME [MODEL]: switches the provider for this run. The model
# does not carry over (ids differ between providers); the conversation does,
# minus the reasoning text of the old model.
provider_use() {
  local name="${1:-}" model="${2:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: /provider use <name> [model]   (/provider list)"
    return 0
  fi
  if ! resolve_provider "$name" 0; then
    printf 'agent.sh: %s\n' "$R_ERR" >&2
    return 0
  fi
  if [[ -n "$model" ]]; then R_MODEL="$model"; fi
  commit_provider
  MESSAGES=$(jq -c 'map(del(.reasoning_content))' <<<"$MESSAGES")
  : >"$TMP/models"
  printf 'provider = %s, model = %s\n' "$PROVIDER" "$MODEL"
  if [[ "$PKIND" != local ]] && [[ "$URL" != https://* ]]; then
    printf 'warning: %s is not https; the key is sent unencrypted\n' \
      "$URL" >&2
  fi
}

# The endpoint that lists the models, derived from the chat endpoint
models_url() {
  local u="${URL%/}"
  u="${u%/chat/completions}"
  printf '%s/models' "$u"
}

# One top-level string/number/boolean field of a JSON config; empty if absent.
config_get() {
  jq -r --arg k "$2" '
    if type == "object" then .[$k] // empty else empty end
    | if type == "string" then .
      elif type == "number" or type == "boolean" then tojson
      else empty end' "$1" 2>/dev/null
}

# Applies one config file; a later file overrides an earlier one.
load_config_file() {
  local f="$1" v
  [[ -f "$f" ]] || return 0
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    printf 'agent.sh: %s is not a JSON object\n' "$f" >&2
    exit 2
  fi
  v=$(config_get "$f" provider)
  if [[ -n "$v" ]]; then PROVIDER="$v"; fi
  # model, url, api_key, reasoning and thinking at the top level belong to
  # the provider the file names: load_settings applies them only to it
  v=$(config_get "$f" model)
  if [[ -n "$v" ]]; then CFG_MODEL="$v"; fi
  v=$(config_get "$f" url)
  if [[ -n "$v" ]]; then CFG_URL="$v"; fi
  v=$(config_get "$f" api_key)
  if [[ -n "$v" ]]; then CFG_API_KEY="$v"; fi
  # Web search: the environment wins over the file
  v=$(config_get "$f" brave_api_key)
  if [[ -n "$v" && -z "$BRAVE_KEY" ]]; then BRAVE_KEY="$v"; fi
  v=$(config_get "$f" tavily_api_key)
  if [[ -n "$v" && -z "$TAVILY_KEY" ]]; then TAVILY_KEY="$v"; fi
  v=$(config_get "$f" searxng_url)
  if [[ -n "$v" && -z "$SEARXNG_URL" ]]; then SEARXNG_URL="$v"; fi
  v=$(config_get "$f" reasoning)
  if [[ -n "$v" ]]; then
    CFG_REASONING_SET=1
    case "$v" in
      default|off|none) CFG_REASONING="" ;;
      *) CFG_REASONING="$v" ;;
    esac
  fi
  v=$(config_get "$f" thinking)
  if [[ -n "$v" ]]; then
    CFG_THINKING_SET=1
    case "$v" in
      default|auto) CFG_THINKING="" ;;
      *) CFG_THINKING="$v" ;;
    esac
  fi
  v=$(config_get "$f" temperature)
  if [[ -n "$v" ]]; then TEMPERATURE="$v"; fi
}

# Config file(s) first, then the environment, then defaults. Refuses settings
# that cannot work instead of sending a bad request later.
load_settings() {
  load_config_file "$SYSTEM_CONFIG_FILE"
  load_config_file "$CONFIG_FILE"
  if [[ -f "$CONFIG_FILE" ]]; then CONFIG_LOADED=1; fi

  CFG_PROVIDER="$PROVIDER"
  if [[ -n "$PROVIDER_ENV_SET" ]]; then PROVIDER="$PROVIDER_ENV"; fi
  if [[ "$(canon_provider "$CFG_PROVIDER")" == \
        "$(canon_provider "$PROVIDER")" ]]; then
    if [[ -n "$CFG_MODEL" ]]; then MODEL="$CFG_MODEL"; MODEL_GIVEN=1; fi
    if [[ -n "$CFG_URL" ]]; then URL="$CFG_URL"; URL_GIVEN=1; fi
    if [[ -n "$CFG_API_KEY" ]]; then
      API_KEY="$CFG_API_KEY"; API_KEY_SOURCE="config"
    fi
    if (( CFG_REASONING_SET )); then
      REASONING="$CFG_REASONING"; REASONING_GIVEN=1
    fi
    if (( CFG_THINKING_SET )); then THINKING="$CFG_THINKING"; fi
  elif [[ -n "$CFG_MODEL$CFG_URL$CFG_API_KEY" ]] || (( CFG_REASONING_SET ||
         CFG_THINKING_SET )); then
    printf 'agent.sh: note: the model, url, api_key, reasoning and thinking' >&2
    printf ' at the top of %s are for provider "%s", not "%s"; use' \
      "$CONFIG_FILE" "$CFG_PROVIDER" "$PROVIDER" >&2
    printf ' "providers" for more\n' >&2
  fi
  if [[ -n "$URL_ENV" ]]; then URL="$URL_ENV"; URL_GIVEN=1; fi
  if [[ -n "$MODEL_ENV_SET" ]]; then MODEL="$MODEL_ENV"; MODEL_GIVEN=1; fi
  if [[ -n "$REASONING_ENV_SET" ]]; then
    REASONING="$REASONING_ENV"; REASONING_GIVEN=1
  fi
  if [[ -n "$THINKING_ENV_SET" ]]; then THINKING="$THINKING_ENV"; fi
  if [[ -n "$TEMPERATURE_ENV_SET" ]]; then
    TEMPERATURE="$TEMPERATURE_ENV"
  fi
  if (( MODEL_GIVEN )) && [[ -z "$MODEL" ]]; then
    printf 'agent.sh: model must not be empty\n' >&2
    exit 2
  fi
  if ! resolve_provider "$PROVIDER" 1; then
    printf 'agent.sh: %s\n' "$R_ERR" >&2
    exit 2
  fi
  commit_provider
  # The API key travels in a header: say so if nothing encrypts it on the way
  case "$URL" in
    https://*|http://localhost[:/]*|http://127.0.0.1[:/]*|http://\[::1\]*) ;;
    *) printf 'agent.sh: warning: %s is not https; the API key and the' \
         "$URL" >&2
       printf ' conversation are sent unencrypted\n' >&2 ;;
  esac
  case "$REASONING" in
    minimal|low|medium|high|"") ;;
    *) printf '%s\n' \
         'agent.sh: reasoning must be minimal, low, medium, high or default' \
         >&2
       exit 2 ;;
  esac
  case "$THINKING" in
    on|off|"") ;;
    *) printf 'agent.sh: thinking must be on, off or default\n' >&2
       exit 2 ;;
  esac
  if [[ -n "$TEMPERATURE" ]] && ! jq -en --arg t "$TEMPERATURE" \
       '($t | tonumber?) as $n | $n != null and $n >= 0 and $n <= 2' \
       >/dev/null 2>&1; then
    printf 'agent.sh: temperature must be a number from 0 to 2\n' >&2
    exit 2
  fi
}

# A config file with an API key should not be readable by other users. This is
# only a warning: the key may be intentional, e.g. a shared service account.
warn_config_permissions() {
  local f="$CONFIG_FILE" mode
  [[ -f "$f" ]] || return 0
  [[ -n "$(config_get "$f" api_key)" ]] || return 0
  mode=$(stat -c '%a' "$f" 2>/dev/null ||
         stat -f '%Lp' "$f" 2>/dev/null) || return 0
  case "$mode" in
    [0-7][0-7][0-7]) ;;
    *) return 0 ;;
  esac
  if (( (8#$mode & 8#077) != 0 )); then
    printf 'agent.sh: warning: %s contains an api_key but is readable by' \
      "$f" >&2
    printf ' others; run chmod 600 on it\n' >&2
  fi
}

# User prompts first, then the ones shipped beside the script. PROMPT_DIR is
# an explicit override and is checked before both.
build_prompt_dirs() {
  PROMPT_DIRS=()
  if [[ -n "$PROMPT_DIR" ]]; then PROMPT_DIRS+=("$PROMPT_DIR"); fi
  PROMPT_DIRS+=("$CONFIG_DIR/prompts")
  PROMPT_DIRS+=("$INSTALL_DIR/pro.mpts")
}

# First run only: create the config directory and put the prompts shipped
# beside the script there as NAME.md.example. They are examples, not overrides:
# a live copy would shadow the bundled prompt for good and hide its updates.
# Nothing is written if the directory already exists.
init_config_dir() {
  local src="$INSTALL_DIR/pro.mpts" f dst
  [[ -d "$CONFIG_DIR" ]] && return 0
  mkdir -p "$CONFIG_DIR/prompts" 2>/dev/null || return 0
  [[ -d "$src" ]] || return 0
  for f in "$src"/*.md; do
    [[ -f "$f" ]] || continue
    dst="$CONFIG_DIR/prompts/$(basename "$f").example"
    # chmod: a copy from a read-only tree (the Nix store) is read-only too
    cp "$f" "$dst" 2>/dev/null && chmod 644 "$dst" 2>/dev/null || true
  done
  printf 'agent.sh: created %s with the prompts as *.md.example;' \
    "$CONFIG_DIR/prompts" >&2
  printf ' rename one to *.md to override it\n' >&2
}

# FILLED = $1 with the placeholders a prompt file may use replaced:
# {{cwd}} the starting directory, {{workspace}} the workspace, {{os}} the
# system (uname -sm), {{date}} today's date.
fill_placeholders() {
  FILLED=$1
  FILLED=${FILLED//'{{cwd}}'/"$PWD"}
  FILLED=${FILLED//'{{workspace}}'/"${WORKSPACE:-$PWD}"}
  FILLED=${FILLED//'{{os}}'/"${OS_NAME:-}"}
  FILLED=${FILLED//'{{date}}'/"${TODAY:-}"}
}

# Prompt commands: <prompt dir>/commands/NAME.md is the prompt that /NAME
# sends. Its first line may be a description for /help, as an HTML comment
# (<!-- Review the uncommitted changes -->). {{args}} in it stands for what
# was typed after the name; without {{args}}, that text is added at the end.

# CMD_FILE = the file of prompt command $1, or returns 1
find_command() {
  local dir
  for dir in "${PROMPT_DIRS[@]}"; do
    if [[ -f "$dir/commands/$1.md" ]]; then
      CMD_FILE="$dir/commands/$1.md"
      return 0
    fi
  done
  return 1
}

# Prints the prompt of command file $1 for the arguments $2
render_command() {
  local t first args="$2"
  t=$(cat "$1" 2>/dev/null) || t=""
  first=${t%%$'\n'*}
  if [[ "$first" == '<!--'*'-->'* ]]; then t=${t#*$'\n'}; fi
  fill_placeholders "$t"
  t=$FILLED
  if [[ "$t" == *'{{args}}'* ]]; then
    t=${t//'{{args}}'/"$args"}
  elif [[ -n "$args" ]]; then
    t+=$'\n\n'"$args"
  fi
  printf '%s' "$t"
}

# Lists the prompt commands for /help: name and description
list_commands() {
  local dir f name first seen=" "
  for dir in "${PROMPT_DIRS[@]}"; do
    for f in "$dir"/commands/*.md; do
      [[ -f "$f" ]] || continue
      name=${f##*/}; name=${name%.md}
      [[ "$seen" == *" $name "* ]] && continue
      seen+="$name "
      first=$(head -n 1 "$f" 2>/dev/null) || first=""
      if [[ "$first" == '<!--'*'-->'* ]]; then
        first=${first#'<!--'}; first=${first%%'-->'*}
        first=${first#"${first%%[![:space:]]*}"}
        first=${first%"${first##*[![:space:]]}"}
      else
        first="prompt from $f"
      fi
      printf '/%-15s %s\n' "$name" "$first"
    done
  done
}

# The text of the first non-blank <prompt dir>/$1, else $2, with the
# placeholders filled in.
read_prompt() {
  local name="$1" fallback="$2" dir f t=""
  PROMPT_FROM="built-in"
  for dir in "${PROMPT_DIRS[@]}"; do
    f="$dir/$name"
    [[ -f "$f" ]] || continue
    t=$(cat "$f" 2>/dev/null) || t=""
    t=${t#"${t%%[![:space:]]*}"}          # trim, a blank file falls back too
    t=${t%"${t##*[![:space:]]}"}
    if [[ -n "$t" ]]; then PROMPT_FROM="$f"; break; fi
  done
  fill_placeholders "${t:-$fallback}"
  printf '%s' "$FILLED"
}

# Which prompts are in use, for /about
prompt_notes() {
  local f n=""
  for f in SYSTEM.md COMPACTION.md PLAN.md EXPLORE.md; do
    read_prompt "$f" '' >/dev/null
    if [[ "$PROMPT_FROM" != built-in ]]; then
      n+="${n:+; }$f from $PROMPT_FROM"
    fi
  done
  if [[ -n "$n" ]]; then printf '%s' "$n"; else printf 'built-in'; fi
}

# Prints the 20 most recent saved sessions ($1 = "all" for every directory)
list_sessions() {
  local f n=0 cur id count preview cwd when
  while IFS= read -r f; do
    IFS=$'\t' read -r cur id count preview cwd < <(
      jq -r --arg pwd "$PWD" --arg all "${1:-}" --arg cur "${SESSION_ID:-}" '
        select($all == "all" or .cwd == $pwd)
        | [.messages[] | select(.role == "user") | .content] as $u
        | [(if .id == $cur then "*" else " " end), .id, ($u | length),
           ($u[0] // "" | gsub("\\s+"; " ") | .[:50]
            | if . == "" or . == " " then "-" else . end),
           .cwd] | @tsv' "$f" 2>/dev/null) || continue
    # (no empty fields: read would shift them)
    when=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null ||
           stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")
    printf '%s %s  %-36s %3s msgs  %s' "$cur" "$when" "$id" "$count" "$preview"
    if [[ "${1:-}" == all ]]; then printf '  \033[2m%s\033[0m' "$cwd"; fi
    printf '\n'
    (( ++n >= 20 )) && break
  done < <(ls -t "$SESSION_DIR"/*.json 2>/dev/null)
  if (( n == 0 )); then
    if [[ "${1:-}" == all ]]; then echo "No saved sessions."
    else echo "No saved sessions for $PWD (try: all)."; fi
  fi
  return 0
}

usage() { sed -n '7,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0"; }

# The current model settings (REPL: /model or /model info)
model_info() {
  printf '  %-11s %s\n' provider "$PROVIDER"
  printf '  %-11s %s\n' model "$MODEL"
  printf '  %-11s %s\n' reasoning "${REASONING:-server default}"
  printf '  %-11s %s\n' thinking "${THINKING:-server default}"
  printf '  %-11s %s\n' temperature "${TEMPERATURE:-server default}"
  if (( CONTEXT > 0 )); then
    printf '  %-11s %s tokens (compacts at %s bytes)\n' context "$CONTEXT" \
      "$COMPACT_AT"
  else
    printf '  %-11s unknown (compacts at %s bytes)\n' context "$COMPACT_AT"
  fi
  printf '  %-11s %s\n' endpoint "$URL"
  printf 'Change one with: /model set <model|reasoning|thinking|'\
'temperature|context|compact_at> <value>\n'
}

# /context: the window and where the history compacts (REPL: /context)
context_info() {
  if (( CONTEXT > 0 )); then
    printf '  %-11s %s tokens\n' context "$CONTEXT"
  else
    printf '  %-11s unknown\n' context
  fi
  printf '  %-11s %s bytes%s\n' compact-at "$COMPACT_AT" \
    "$( (( COMPACT_AT_AUTO )) && echo ' (follows the context)' || true)"
  printf '  %-11s %s bytes\n' history "$(( ${#MESSAGES} ))"
  echo "Change: /context <tokens|default>   /context compact <bytes|default>"
}

# /model set <key> <value>: validates and stores one setting for this run
set_model() {
  local key="${1:-}" val="${2:-}" rest="${3:-}"
  case "$key" in
    temp)   key=temperature ;;
    effort) key=reasoning ;;
  esac
  case "$key" in
    model|reasoning|thinking|temperature|context|compact_at) ;;
    "") echo "Usage: /model set <model|reasoning|thinking|temperature|"\
             "context|compact_at> <value>"; return 0 ;;
    *)  echo "Unknown setting '$key' (model, reasoning, thinking,"\
             "temperature, context or compact_at)."; return 0 ;;
  esac
  if [[ -z "$val" || -n "$rest" ]]; then
    printf 'Usage: /model set %s <value>\n' "$key"; return 0
  fi
  case "$key" in
    model) MODEL="$val" ;;
    reasoning)
      case "$val" in
        minimal|low|medium|high) REASONING="$val" ;;
        default|off|none)        REASONING="" ;;
        *)  echo "Reasoning must be minimal, low, medium, high or default."
            return 0 ;;
      esac ;;
    thinking)
      case "$val" in
        on|yes|true|1|enabled)   THINKING=on ;;
        off|no|false|0|disabled) THINKING=off ;;
        default|auto)            THINKING="" ;;
        *)  printf 'Thinking must be on, off or default.\n'; return 0 ;;
      esac ;;
    temperature)
      if [[ "$val" == default ]]; then
        TEMPERATURE=""
      elif jq -en --arg t "$val" \
           '($t | tonumber?) as $n | $n != null and $n >= 0 and $n <= 2' \
           >/dev/null 2>&1; then
        TEMPERATURE="$val"
      else
        printf 'Temperature must be a number from 0 to 2, or default.\n'
        return 0
      fi ;;
    context)
      # the window in tokens; compaction follows it unless COMPACT_AT was set
      if [[ "$val" == default || "$val" == 0 ]]; then CONTEXT=0
      elif [[ "$val" =~ ^[1-9][0-9]*$ ]]; then CONTEXT="$val"
      else
        echo "Context must be a number of tokens, or default (unknown)."
        return 0
      fi
      if (( COMPACT_AT_AUTO )); then
        if (( CONTEXT > 0 )); then COMPACT_AT=$(( CONTEXT * 2 ))
        else COMPACT_AT=100000; fi
      fi ;;
    compact_at)
      if [[ "$val" == default ]]; then
        COMPACT_AT_AUTO=1
        if (( CONTEXT > 0 )); then COMPACT_AT=$(( CONTEXT * 2 ))
        else COMPACT_AT=100000; fi
      elif [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
        COMPACT_AT="$val"; COMPACT_AT_AUTO=0
      else
        echo "compact_at must be a number of bytes, or default."
        return 0
      fi ;;
  esac
  case "$key" in
    model)       printf 'model = %s\n' "$MODEL" ;;
    reasoning)   printf 'reasoning = %s\n' "${REASONING:-server default}" ;;
    thinking)    printf 'thinking = %s\n' "${THINKING:-server default}" ;;
    temperature) printf 'temperature = %s\n' "${TEMPERATURE:-server default}" ;;
    context|compact_at)
      if (( CONTEXT > 0 )); then
        printf 'context = %s tokens, compacts at %s bytes\n' "$CONTEXT" \
          "$COMPACT_AT"
      else
        printf 'context = unknown, compacts at %s bytes\n' "$COMPACT_AT"
      fi
      if (( CONTEXT > 0 && COMPACT_AT >= CONTEXT * 4 )); then
        echo "warning: compact_at reaches the context window; lower it"
      fi ;;
  esac
}

# Fetches the endpoint's model list into $TMP/models, one id per line.
# Explains a failure and returns non-zero; the current model is untouched.
fetch_models() {
  local url code note
  if [[ "$PKIND" == copilot ]] && ! copilot_session; then
    printf 'agent.sh: %s\n' "$COPILOT_LAST_ERR" >&2
    return 1
  fi
  ensure_tmp
  url=$(models_url)
  : >"$TMP/models"   # never resolve /model use against a stale list
  code=$(curl -sS --connect-timeout 30 --max-time "$TIMEOUT" \
    -D "$TMP/models.hdr" -o "$TMP/models.json" \
    -H @"$TMP/auth" -H "Accept: application/json" "${url}" 2>"$TMP/curl.err" \
    && awk '/^HTTP\//{c = $2} END{print c}' "$TMP/models.hdr") || code=""
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    printf 'agent.sh: cannot list models from %s%s\n' "$url" \
      "${code:+ (HTTP $code)}" >&2
    [[ -s "$TMP/curl.err" ]] && sed 's/^/  /' "$TMP/curl.err" >&2
    note=$(reply_note "$TMP/models.json") || note=""
    [[ -n "$note" ]] && printf '  the server said: %s\n' "$note" >&2
    return 1
  fi
  if ! jq -r '(.data // .models // [])[]
               | select((.capabilities.type? // "chat") == "chat")
               | (.id // .name // empty)' "$TMP/models.json" \
       >"$TMP/models" 2>/dev/null || [[ ! -s "$TMP/models" ]]; then
    printf 'agent.sh: %s returned no model list\n' "$url" >&2
    return 1
  fi
}

# /model list: the models the endpoint offers, the current one marked
model_list() {
  local n=0 id
  if ! fetch_models; then return 0; fi
  printf 'Models at %s:\n' "$(models_url)"
  while IFS= read -r id; do
    n=$((n + 1))
    if [[ "$id" == "$MODEL" ]]; then
      printf '  \033[1m%2d  %s  *\033[0m\n' "$n" "$id"
    else
      printf '  %2d  %s\n' "$n" "$id"
    fi
  done <"$TMP/models"
  echo "Switch with: /model use <number or name>"
}

# /model use <number or name>: switches the model for this run
model_use() {
  local want="${1:-}" pick="" n=0 id
  if [[ -z "$want" ]]; then
    echo "Usage: /model use <number or name> (list them: /model list)"
    return 0
  fi
  [[ -s "$TMP/models" ]] || fetch_models || return 0
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    while IFS= read -r id; do
      n=$((n + 1))
      if (( n == want )); then pick="$id"; break; fi
    done <"$TMP/models"
    if [[ -z "$pick" ]]; then
      printf 'No model number %s (the list has %s; see: /model list)\n' \
        "$want" "$n"
      return 0
    fi
  else
    pick="$want"
    if ! grep -Fxq -- "$pick" "$TMP/models"; then
      printf '%s\n' \
        "warning: $pick is not in the list; sending it anyway" >&2
    fi
  fi
  MODEL="$pick"
  printf 'model = %s\n' "$MODEL"
  if (( CONTEXT > 0 )); then
    printf '(compacts at %s bytes still; for the new model: ' "$COMPACT_AT"
    printf '/model set context <tokens>)\n'
  fi
}

# Version and environment details (REPL: /about, CLI: -V or --version)
about() {
  local jq_ver curl_ver run cfg_note="" f plugins=""
  jq_ver=$(jq --version 2>/dev/null); jq_ver=${jq_ver/jq-/jq }
  curl_ver=$(curl --version 2>/dev/null | head -1 | cut -d' ' -f1,2)
  if [[ "$AUTO" == 1 ]]; then run="run without asking"; else run="ask first"; fi
  if (( CONFIG_LOADED )); then cfg_note=" (loaded)"; fi
  printf 'agent.sh %s — a coding agent in bash\n' "$VERSION"
  printf '  %-9s %s\n' author "$AUTHOR"
  printf '  %-9s %s\n' released "$RELEASED"
  printf '  %-9s MIT (see LICENSE)\n' license
  printf '  %-9s %s\n' config "$CONFIG_FILE$cfg_note"
  printf '  %-9s %s\n' provider "$PROVIDER"
  printf '  %-9s %s\n' model "$MODEL"
  printf '  %-9s reasoning %s, thinking %s, temperature %s\n' params \
    "${REASONING:-default}" "${THINKING:-default}" \
    "${TEMPERATURE:-default}"
  printf '  %-9s %s\n' endpoint "$URL"
  printf '  %-9s set (%s)\n' api-key "${API_KEY_SOURCE:-unknown}"
  printf '  %-9s %s\n' session "$SESSION_ID"
  printf '  %-9s %s\n' sessions "$SESSION_DIR"
  printf '  %-9s %s\n' auto "$run"
  if [[ "$MODE" == plan ]]; then
    printf '  %-9s %s\n' mode 'plan (read-only commands, no edits)'
  else
    printf '  %-9s %s\n' mode 'build (edits and commands allowed)'
  fi
  if (( AUTO_COMPACT )); then
    if (( CONTEXT > 0 )); then
      printf '  %-9s automatic above %s bytes (%s tokens)\n' compact \
        "$COMPACT_AT" "$(( COMPACT_AT / 4 ))"
    else
      printf '  %-9s automatic above %s bytes\n' compact "$COMPACT_AT"
    fi
  else
    printf '  %-9s only with /compact\n' compact
  fi
  printf '  %-9s %s\n' prompts "$(prompt_notes)"
  printf '  %-9s %s\n' project "${PROJECT_DOC_USED:-no AGENTS.md here}"
  printf '  %-9s %s (outside it: %s)\n' workspace "${WORKSPACE:-$PWD}" \
    "$OUTSIDE"
  printf '  %-9s %s\n' tools "$TOOL_NAMES"
  if [[ -n "$CLI_FOUND" ]]; then
    printf '  %-9s %s%s\n' cli "$CLI_FOUND" \
      "$( [[ "$CLI_HINTS" == 0 ]] && echo ' (not suggested: CLI_HINTS=0)')"
  fi
  if [[ -n "$PLUGIN_FILES" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && plugins+="${f##*/} "
    done <<<"$PLUGIN_FILES"
    printf '  %-9s %s\n' plugins "$plugins"
  fi
  if (( WEB )); then
    if [[ -n "$BRAVE_KEY" ]]; then printf '  %-9s Brave\n' search
    elif [[ -n "$TAVILY_KEY" ]]; then printf '  %-9s Tavily\n' search
    elif [[ -n "$SEARXNG_URL" ]]; then printf '  %-9s %s\n' search "$SEARXNG_URL"
    else printf '  %-9s DuckDuckGo (no key; may refuse requests)\n' search
    fi
  fi
  if (( SUBAGENTS )); then
    printf '  %-9s explore tool on, up to %s in parallel\n' explorers "$SUB_MAX"
  else
    printf '  %-9s off\n' explorers
  fi
  printf '  %-9s %s, %s, %s\n' runtime \
    "bash $BASH_VERSION" "$jq_ver" "$curl_ver"
  printf '  %-9s %s\n' script "$0"
}

RESUME=""
LIST=0
INTERACTIVE=0
LOGIN=""
# getopts cannot see long options: take them out of the leading options first
# and stop at the first prompt word, so "--plan" inside a prompt is just text.
ARGS=()
while (( $# )); do
  case "$1" in
    --help)    usage; exit 0 ;;
    --version) printf 'agent.sh %s\n' "$VERSION"; exit 0 ;;
    --plan)    ARGS+=(-p); shift ;;       # in order, so the last one wins
    --build)   ARGS+=(-b); shift ;;
    --login)   LOGIN=copilot; shift          # the only login there is
               case "${1:-}" in
                 copilot|github-copilot) shift ;;
                 ""|-*) ;;
                 *) echo "agent.sh: cannot log in to '$1' (only copilot)" >&2
                    exit 2 ;;
               esac ;;
    --)        ARGS+=("$@"); break ;;
    --*)       echo "agent.sh: unknown option $1 (try -h)" >&2; exit 2 ;;
    -r|-[!-]*r)                         # -r takes the next word as its value
               ARGS+=("$1"); shift
               if (( $# )); then ARGS+=("$1"); shift; fi ;;
    -?*)       ARGS+=("$1"); shift ;;
    *)         ARGS+=("$@"); break ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
while getopts ":ycr:lhVpbi" opt; do
  case "$opt" in
    y) AUTO=1 ;;
    p) MODE=plan ;;
    b) MODE=build ;;
    i) INTERACTIVE=1 ;;
    c) RESUME=last ;;
    r) [[ -n "$OPTARG" ]] ||
         { echo "agent.sh: -r needs a session id" >&2; exit 2; }
       RESUME="$OPTARG" ;;
    l) LIST=1 ;;
    h) usage; exit 0 ;;
    V) printf 'agent.sh %s\n' "$VERSION"; exit 0 ;;
    :) echo "agent.sh: -$OPTARG needs an argument" >&2; exit 2 ;;
    *) echo "agent.sh: unknown option -$OPTARG (try -h)" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
# Makes sure program $1 can be run, before anything needs it. If it is not on
# PATH but Nix is here, it is taken from the Nix store: a copy that is already
# there first (no download), else Nix is asked to fetch it. Otherwise the user
# is told what is missing and how to get it.
need() {
  local prog="$1" store="${NIX_STORE_DIR:-/nix/store}" p found="" out line
  command -v "$prog" >/dev/null 2>&1 && return 0
  if [[ -d "$store" ]]; then
    # e.g. /nix/store/<hash>-jq-1.7.1-bin/bin/jq
    for p in "$store"/*-"$prog"-[0-9]*/bin/"$prog"; do
      if [[ -x "$p" ]]; then found="$p"; fi
    done
  fi
  if [[ -z "$found" ]] && command -v nix >/dev/null 2>&1; then
    printf "agent.sh: '%s' is not installed; getting it with Nix...\n" \
      "$prog" >&2
    out=$(nix build --no-link --print-out-paths \
            --extra-experimental-features 'nix-command flakes' \
            "nixpkgs#$prog" 2>/dev/null) || out=""
    if [[ -z "$out" ]] && command -v nix-build >/dev/null 2>&1; then
      out=$(nix-build '<nixpkgs>' -A "$prog" --no-out-link 2>/dev/null) ||
        out=""
    fi
    while IFS= read -r line; do           # one line per output (bin, man, ...)
      if [[ -n "$line" && -x "$line/bin/$prog" ]]; then
        found="$line/bin/$prog"; break
      fi
    done <<<"$out"
  fi
  if [[ -n "$found" ]]; then
    PATH="${found%/*}:$PATH"
    export PATH
    printf "agent.sh: using %s from the Nix store (%s)\n" "$prog" "$found" >&2
    return 0
  fi
  printf "agent.sh: '%s' is required but was not found.\n" "$prog" >&2
  if command -v nix >/dev/null 2>&1; then
    printf '  Nix could not provide it either (no network?). Try:\n' >&2
    printf '    nix profile install nixpkgs#%s\n' "$prog" >&2
  else
    printf '  Install it and run agent.sh again, for example:\n' >&2
    printf '    apt install %s | dnf install %s | brew install %s\n' \
      "$prog" "$prog" "$prog" >&2
    printf '    nix profile install nixpkgs#%s\n' "$prog" >&2
  fi
  exit 1
}
need jq
need curl

if (( LIST )); then list_sessions "${1:-}"; exit 0; fi
FIRST_PROMPT="$*"
ONESHOT=0                              # a prompt on the command line: answer, exit
if [[ -n "$FIRST_PROMPT" ]] && (( ! INTERACTIVE )); then ONESHOT=1; fi
if [[ "$SUB" == 1 ]]; then              # an explorer: read-only, never asks
  MODE=plan; AUTO=1; SUBAGENTS=0; WEB=0; MAX_STEPS="$SUB_MAX_STEPS"
  [[ -n "$FIRST_PROMPT" ]] ||
    { echo "agent.sh: an explorer needs a task" >&2; exit 2; }
  ONESHOT=1
else
  SUB=0
fi
for dep in SUB_MAX SUB_TIMEOUT SUB_MAX_STEPS MAX_STEPS; do
  [[ "${!dep}" =~ ^(0|[1-9][0-9]*)$ ]] ||
    { echo "agent.sh: $dep must be a whole number" >&2; exit 2; }
done
# These are used in (( )): anything but 0 or 1 would be read as a variable name
for dep in AUTO AUTO_COMPACT SHOW_REASONING PROJECT_DOC; do
  [[ "${!dep}" == 0 || "${!dep}" == 1 ]] ||
    { echo "agent.sh: $dep must be 0 or 1" >&2; exit 2; }
done
[[ "$SUBAGENTS" == 0 || "$SUBAGENTS" == 1 ]] ||
  { echo "agent.sh: SUBAGENTS must be 0 or 1" >&2; exit 2; }
[[ "$WEB" == 0 || "$WEB" == 1 ]] ||
  { echo "agent.sh: WEB must be 0 or 1" >&2; exit 2; }
[[ "$CONTEXT" =~ ^(0|[1-9][0-9]*)$ ]] ||
  { echo "agent.sh: CONTEXT must be a whole number (0 = unknown)" >&2
    exit 2; }
# With a known window, compact at half of it, counting 4 bytes per token, so
# the summary request (the whole head plus the prompt) still fits. Without
# one, keep the old byte threshold.
COMPACT_AT_AUTO=0
if [[ -z "$COMPACT_AT" ]]; then
  COMPACT_AT_AUTO=1
  if (( CONTEXT > 0 )); then COMPACT_AT=$(( CONTEXT * 2 ))
  else COMPACT_AT=100000; fi
fi
for dep in WEB_TIMEOUT READ_LINES MAX_OUT COMPACT_AT TIMEOUT \
           AGENT_HISTORY_MAX; do
  [[ "${!dep}" =~ ^[1-9][0-9]*$ ]] ||
    { echo "agent.sh: $dep must be a whole number above 0" >&2; exit 2; }
done
# A threshold at or past the window cannot be compacted in one request
if (( CONTEXT > 0 && COMPACT_AT >= CONTEXT * 4 )); then
  printf 'agent.sh: warning: COMPACT_AT (%s bytes) reaches the %s-token' \
    "$COMPACT_AT" "$CONTEXT" >&2
  printf ' context window; raise CONTEXT or lower COMPACT_AT\n' >&2
fi
(( SUB_MAX > 0 )) || SUB_MAX=1
case "$OUTSIDE" in
  ask|allow|deny) ;;
  *) echo "agent.sh: OUTSIDE must be ask, allow or deny" >&2; exit 2 ;;
esac
case "$MODE" in
  build|plan) ;;
  *) echo "agent.sh: MODE must be 'build' or 'plan'" >&2; exit 2 ;;
esac

SELF=$(resolve_self)
INSTALL_DIR=$(dirname "$SELF")
build_prompt_dirs
init_config_dir
load_plugins
if [[ -n "$LOGIN" ]]; then copilot_login; exit; fi
load_settings
warn_config_permissions

START_DIR="$PWD"
# The workspace: where commands may work without a question. The repository
# that contains the starting directory, if there is one, else that directory.
if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null) ||
    WORKSPACE=""
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$START_DIR"               # not in a repository
  else
    case "$START_DIR/" in
      "$WORKSPACE"/*) ;;
      *) WORKSPACE="$START_DIR" ;;       # reached through a symbolic link
    esac
  fi
fi
WORKSPACE=${WORKSPACE%/}
[[ -n "$WORKSPACE" ]] || WORKSPACE=/
# System locations a normal user can read but not change, and scratch space:
# naming these needs no question.
OUTSIDE_ALLOW=(/usr /bin /sbin /lib /lib32 /lib64 /libexec /opt /etc
               /nix/store /run/current-system /proc /sys /dev /tmp /var/tmp
               /private/tmp)
if [[ -n "${TMPDIR:-}" ]]; then OUTSIDE_ALLOW+=("${TMPDIR%/}"); fi
if [[ -n "$ALLOW_PATHS" ]]; then
  IFS=: read -ra dep <<<"$ALLOW_PATHS"
  for pid in ${dep[@]+"${dep[@]}"}; do
    if [[ "$pid" == /* ]]; then OUTSIDE_ALLOW+=("${pid%/}"); fi
  done
fi
WORKSPACE_PHYS=$(cd -P "$WORKSPACE" 2>/dev/null && pwd -P) || WORKSPACE_PHYS=""
OS_NAME=$(uname -sm 2>/dev/null) || OS_NAME="unknown"
TODAY=$(date '+%Y-%m-%d' 2>/dev/null) || TODAY=""

SYSTEM_DEFAULT="You are a coding agent working in the user's current directory
($PWD). Use the bash tool to inspect, create, edit and run files. Each command
runs in a fresh non-interactive bash process with no stdin, so 'cd' and
variables do not persist between calls and interactive programs will not work.
A command returns only when everything it started has closed its output, so
send a background job's output to a file (cmd >log 2>&1 &). If you have the
explore tool, use it to look into several independent things at once. Stop
processes by PID, never by a name that could match your own shell (pkill bash,
killall, kill -1). Be concise."
PLAN_DEFAULT='PLAN MODE: plan only, do not change anything. Inspect the '
PLAN_DEFAULT+='project with read-only commands (ls, cat, head, tail, grep, '
PLAN_DEFAULT+='git status/diff/log/show, ...); other commands are refused '
PLAN_DEFAULT+='by the harness. Do not edit, create or delete files, commit '
PLAN_DEFAULT+='or run builds and tests that touch the tree. Finish with a '
PLAN_DEFAULT+='concrete, step-by-step plan: the files to change, the exact '
PLAN_DEFAULT+='edits, and how to verify them. Say what you would do, not '
PLAN_DEFAULT+='what you did.'
BASE_SYSTEM=$(read_prompt SYSTEM.md "$SYSTEM_DEFAULT")
# Project instructions: ./AGENTS.md joins the system prompt (PROJECT_DOC=0
# turns that off). Capped, so a huge file cannot eat the context.
PROJECT_DOC_USED=""
if [[ "$PROJECT_DOC" != 0 && -f AGENTS.md && -r AGENTS.md ]]; then
  doc=$(head -c 20000 AGENTS.md | tr -d '\0')
  if [[ -n "${doc//[[:space:]]/}" ]]; then
    BASE_SYSTEM+=$'\n\n'"Project instructions from $PWD/AGENTS.md:"$'\n'"$doc"
    PROJECT_DOC_USED="$PWD/AGENTS.md"
  fi
fi
# Fast command-line tools found on this machine, so the model reaches for
# them instead of grep -r and find. CLI_HINTS=0 leaves this out.
cli_tools() {
  local t
  CLI_FOUND=""; CLI_FD=""; CLI_BAT=""
  for t in rg fzf ast-grep tree; do
    command -v "$t" >/dev/null 2>&1 && CLI_FOUND+="$t "
  done
  # Debian and Ubuntu ship fd and bat under other names
  for t in fd fdfind; do
    if command -v "$t" >/dev/null 2>&1; then CLI_FD="$t"; break; fi
  done
  for t in bat batcat; do
    if command -v "$t" >/dev/null 2>&1; then CLI_BAT="$t"; break; fi
  done
  [[ -z "$CLI_FD" ]] || CLI_FOUND+="$CLI_FD "
  [[ -z "$CLI_BAT" ]] || CLI_FOUND+="$CLI_BAT "
  CLI_FOUND=${CLI_FOUND% }
}
cli_hints() {
  local h=""
  [[ -n "$CLI_FOUND" ]] || return 0
  h="Fast tools are installed here; use them in bash instead of the slower "
  h+="classic ones (rg and fd skip .gitignore'd and hidden files by default):"
  if [[ " $CLI_FOUND " == *" rg "* ]]; then
    h+=$'
'"- rg PATTERN [PATH]: search file contents instead of grep -r"
    h+=" (rg -n -C2 for context, -l for file names, -t py to filter by"
    h+=" type, -F for a literal string, --hidden/-uu to include ignored files)"
  fi
  if [[ -n "$CLI_FD" ]]; then
    h+=$'
'"- $CLI_FD PATTERN [PATH]: find files by name instead of find"
    h+=" ($CLI_FD -e ts for an extension, -t f / -t d for files or"
    h+=" directories, -H to include hidden ones)"
  fi
  if [[ " $CLI_FOUND " == *" fzf "* ]]; then
    h+=$'
'"- fzf --filter TEXT: fuzzy-match lines read on stdin, best first,"
    h+=" for a file whose exact name you do not know (e.g."
    if [[ -n "$CLI_FD" ]]; then h+=" $CLI_FD -t f | fzf --filter usrctl"
    else h+=" rg --files | fzf --filter usrctl"; fi
    h+=" | head). Never run fzf without --filter: there is no terminal."
  fi
  if [[ " $CLI_FOUND " == *" ast-grep "* ]]; then
    h+=$'
'"- ast-grep -p 'PATTERN' -l LANG: search code by syntax (e.g."
    h+=" ast-grep -p 'console.log(\$A)' -l js); it ignores formatting"
  fi
  if [[ " $CLI_FOUND " == *" tree "* ]]; then
    h+=$'
'"- tree -L 2 --gitignore: the layout of a directory"
  fi
  # bat is for people: the read tool is better for the model, so no hint
  printf '%s' "$h"
}
CLI_HINTS="${CLI_HINTS:-1}"
cli_tools
if [[ "$CLI_HINTS" != 0 ]]; then
  hints=$(cli_hints)
  if [[ -n "$hints" ]]; then BASE_SYSTEM+=$'\n\n'"$hints"; fi
fi
PLAN_PROMPT=$(read_prompt PLAN.md "$PLAN_DEFAULT")
EXPLORE_DEFAULT='You are an explorer: a read-only sub-agent working for '
EXPLORE_DEFAULT+='another agent, which gave you the task below and cannot see '
EXPLORE_DEFAULT+='anything you do except your final message. Inspect the '
EXPLORE_DEFAULT+='project with read-only commands (ls, cat, head, tail, grep, '
EXPLORE_DEFAULT+='find, git log/show/diff, ...); other commands are refused by '
EXPLORE_DEFAULT+='the harness. Do not ask questions. Use few steps, then end '
EXPLORE_DEFAULT+='with a short report: what you found, with file paths and '
EXPLORE_DEFAULT+='line numbers, the facts the task asked for, and what you '
EXPLORE_DEFAULT+='could not determine. Report only what you saw.'
EXPLORE_PROMPT=$(read_prompt EXPLORE.md "$EXPLORE_DEFAULT")
SYSTEM="$BASE_SYSTEM"

# OpenAI-style tool definitions. An explorer gets bash and read only.
# Built with jq: a JSON string cannot be broken across lines
TOOLS=$(jq -cn --argjson explore "$SUBAGENTS" --argjson web "$WEB" \
              --argjson sub "$SUB" --argjson lines "$READ_LINES" \
              --arg search "$(
                if [[ " $CLI_FOUND " == *" rg "* ]]; then printf 'rg'
                else printf 'grep -rn'; fi
                if [[ -n "$CLI_FD" ]]; then printf ', %s' "$CLI_FD"
                else printf ', find'; fi
                printf ', ls')" \
              --argjson plugin_tools "$(if (( SUB )); then echo '[]'
                               else echo "$PLUGIN_TOOLS_JSON"; fi)" '
  def tool(n; d; props; req):
    {type: "function", function: {name: n, description: d,
      parameters: {type: "object", properties: props, required: req}}};
  [tool("bash";
     "Run a bash script in the working directory and return its combined "
     + "stdout and stderr, plus the exit code if it is not 0. Each call is a "
     + "new non-interactive shell: nothing carries over, and there is no "
     + "terminal or stdin. Use it to run builds, tests, git and any other "
     + "program, and to search (\($search)).";
     {command: {type: "string",
                description: "The bash command or script to run"}};
     ["command"]),
   tool("read";
     "Read a text file. Returns the lines with their line numbers "
     + "(\"    12<TAB>text\"), at most \($lines) lines per call; use offset "
     + "to read further. Prefer this to cat: it needs no approval inside "
     + "the workspace.";
     {path: {type: "string",
             description: ("File path, absolute or relative to the "
                           + "working directory")},
      offset: {type: "integer",
               description: "First line to return, counted from 1"},
      limit: {type: "integer", description: "How many lines to return"}};
     ["path"])]
  + (if $sub == 1 then [] else
  [tool("edit";
     "Change a file by replacing text. old must match the file exactly "
     + "(every space, tab and line break) and, unless replace_all is true, "
     + "in exactly one place: include enough surrounding lines to make it "
     + "unique. Copy old from a read result without the line numbers. Read "
     + "the file first.";
     {path: {type: "string", description: "File to change"},
      old: {type: "string", description: "The exact text to replace"},
      new: {type: "string", description: "The text to put in its place"},
      replace_all: {type: "boolean",
                    description: "Replace every match instead of one"}};
     ["path", "old", "new"]),
   tool("write";
     "Create a file, or replace the whole content of an existing one. "
     + "Missing directories are created. For a change to part of an "
     + "existing file, use edit instead.";
     {path: {type: "string", description: "File to create or replace"},
      content: {type: "string", description: "The complete file content"}};
     ["path", "content"])] end)
  + (if $web == 1 then
  [tool("web_search";
     "Search the web. Returns numbered results: title, URL and a short "
     + "snippet. Use it for things that may have changed or that you do not "
     + "know: current versions, error messages, API documentation. Follow "
     + "up with web_fetch on the best result; do not answer from snippets "
     + "alone.";
     {query: {type: "string", description: "Search terms, a few words"},
      count: {type: "integer",
              description: "Results to return, 1-10 (default 5)"}};
     ["query"]),
   tool("web_fetch";
     "Fetch a web page or file by URL (http or https) and return its text; "
     + "HTML is converted to plain text. Use it to read documentation, "
     + "release notes or an issue the user linked.";
     {url: {type: "string", description: "The full URL"}};
     ["url"])]
  else [] end)
  + (if $sub == 1 then [] else
  [tool("todo";
     "Keep a todo list for a task with several steps (three or more), so "
     + "you and the user can see the plan and the progress. Send the whole "
     + "list every time: it replaces the old one. Keep one item "
     + "in_progress at a time, mark it done as soon as it is finished, and "
     + "add, drop or reword items as the plan changes. Skip it for a "
     + "quick question or a one-step change.";
     {items: {type: "array", description: "The complete list, in order",
              items: {type: "object",
                      properties: {
                        text: {type: "string",
                               description: "What to do, one short line"},
                        status: {type: "string",
                                 enum: ["pending", "in_progress", "done"]}},
                      required: ["text", "status"]}}};
     ["items"])] end)
  + (if $explore == 1 then
  [tool("explore";
     "Start a read-only sub-agent that explores the project and returns a "
     + "report. It can only read files and run read-only commands, and it "
     + "does not see this conversation, so give it a self-contained task: "
     + "what to find out, where to look, and what to report. Several "
     + "explore calls in one reply run in parallel: split a broad search "
     + "into independent tasks. For one quick lookup, use read or bash "
     + "yourself.";
     {task: {type: "string",
             description: "What the explorer should find out and report"}};
     ["task"])]
  else [] end)
  + $plugin_tools')
TOOL_NAMES=$(jq -r '[.[].function.name] | join(", ")' <<<"$TOOLS")

# Scratch files live beside the sessions, not in /tmp: a command that cleans
# /tmp must not take the agent's files with it. The directory name carries our
# pid, so a later run can remove what a killed one left behind.
RUN_BASE="${SESSION_DIR%/*}"
mkdir -p "$RUN_BASE" 2>/dev/null || true
for dep in "$RUN_BASE"/run.*; do
  [[ -d "$dep" ]] || continue
  pid=${dep##*/run.}; pid=${pid%%.*}
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  kill -0 "$pid" 2>/dev/null || rm -rf "$dep" 2>/dev/null || true
done
TMP=$(mktemp -d "$RUN_BASE/run.$$.XXXXXX" 2>/dev/null) || TMP=$(mktemp -d)
CMD_PID=""                 # process group of the command now running, if any
on_exit() {
  if [[ -n "$CMD_PID" ]]; then kill -TERM -- "-$CMD_PID" 2>/dev/null || true; fi
  if declare -F sub_kill_all >/dev/null; then sub_kill_all; fi
  rm -rf "$TMP"
}
trap on_exit EXIT
trap 'exit 129' HUP        # terminal closed: leave through on_exit
# An explorer is stopped by its parent with TERM: take the command with it
if (( SUB )); then trap 'exit 143' TERM; fi

# Puts back the scratch directory and the key file if a command removed them.
# The key goes to curl in a file: on the command line any user could read it
# with ps. printf is a builtin, so it does not show up there either.
ensure_tmp() {
  [[ -d "$TMP" ]] || mkdir -p "$TMP" 2>/dev/null || true
  [[ -s "$TMP/auth" ]] || write_auth
}
ensure_tmp
# "timeout" caps a command's run time where it exists (gtimeout: macOS with
# coreutils). "setsid" gives a command its own session; without it, job
# control gives it at least its own process group.
TIMEOUT_BIN=""
for dep in timeout gtimeout; do
  if command -v "$dep" >/dev/null 2>&1 && "$dep" 5 true >/dev/null 2>&1; then
    TIMEOUT_BIN="$dep"; break
  fi
done
SETSID_BIN=""
if command -v setsid >/dev/null 2>&1 && setsid true >/dev/null 2>&1; then
  SETSID_BIN=setsid
fi
[[ "$CMD_TIMEOUT" =~ ^(0|[1-9][0-9]*)$ ]] ||
  { echo "agent.sh: CMD_TIMEOUT must be a whole number of seconds" >&2; exit 2; }
# Ctrl-C kills the foreground child (curl / the command) but not the agent
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

# ---------------------------------------------------------------- sessions

session_file() { printf '%s/%s.json' "$SESSION_DIR" "$SESSION_ID"; }

# Some models are served only by the /responses API. RESP_MODELS lists the
# "provider/model" pairs known to need it (learned when /chat/completions
# refuses one and /responses takes it; an explorer inherits the list).
uses_responses() { [[ " $RESP_MODELS " == *" $PROVIDER/$MODEL "* ]]; }

# The settings a conversation was held with, saved beside it. Never the key
# or the URL: those come from where the session is resumed.
settings_json() {
  local api=chat
  if uses_responses; then api=responses; fi
  jq -cn --arg provider "$PROVIDER" --arg model "$MODEL" --arg api "$api" \
    --arg reasoning "$REASONING" --arg thinking "$THINKING" \
    --arg temperature "$TEMPERATURE" --arg context "$CONTEXT" \
    --arg compact_at "$(if (( COMPACT_AT_AUTO )); then echo auto
                        else echo "$COMPACT_AT"; fi)" \
    '{provider: $provider, model: $model, api: $api, reasoning: $reasoning,
      thinking: $thinking, temperature: $temperature,
      context: ($context | tonumber), compact_at: $compact_at}'
}

save_session() {
  local f settings; f=$(session_file)
  settings=$(settings_json)
  LAST_SETTINGS="$settings"
  [[ -d "$SESSION_DIR" ]] || mkdir -p "$SESSION_DIR" 2>/dev/null || true
  if ! jq -c --arg id "$SESSION_ID" --arg cwd "$PWD" \
         --argjson settings "$settings" --argjson todos "$TODOS" \
         '{id: $id, cwd: $cwd, settings: $settings, todos: $todos,
           messages: .}' \
         <<<"$MESSAGES" >"$f.$$.tmp" 2>/dev/null ||
     ! mv -f "$f.$$.tmp" "$f"; then
    echo "warning: could not save session to $f" >&2
  fi
}

new_history() {
  TODOS='[]'
  MESSAGES=$(jq -cn --arg s "$SYSTEM" '[{role: "system", content: $s}]')
}

# Switches mode and keeps the system message at the head of the history in
# step, so the model sees the rules of the mode the user is in.
apply_mode() {
  MODE="$1"
  SYSTEM="$BASE_SYSTEM"
  if (( SUB )); then
    SYSTEM+=$'\n\n'"$EXPLORE_PROMPT"
  elif [[ "$MODE" == plan ]]; then
    SYSTEM+=$'\n\n'"$PLAN_PROMPT"
  fi
  [[ -n "${MESSAGES:-}" ]] || return 0
  MESSAGES=$(jq -c --arg s "$SYSTEM" '
    if (.[0].role // "") == "system" then .[0].content = $s else . end' \
    <<<"$MESSAGES") || true
}

# Most recently saved session whose cwd is this directory
find_last_session() {
  local f
  while IFS= read -r f; do
    if [[ "$(jq -r '.cwd' "$f" 2>/dev/null)" == "$PWD" ]]; then
      basename "$f" .json
      return 0
    fi
  done < <(ls -t "$SESSION_DIR"/*.json 2>/dev/null)
  return 1
}

# If the agent died mid-turn, answer any tool calls left without a result so
# the history is valid for the API again
REPAIR='
  ([to_entries[] | select(.value.role == "assistant") | .key] | last) as $i
  | if $i == null or ((.[$i].tool_calls // []) | length) == 0 then .
    else [.[$i + 1:][] | select(.role == "tool") | .tool_call_id] as $done
      | . + [.[$i].tool_calls[] | .id as $id
             | select(any($done[]; . == $id) | not)
             | {role: "tool", tool_call_id: $id,
                content: "Not run: the session ended first."}]
    end'

# Resolves a session id or unique id prefix to a saved session id
resolve_session() {
  local f n=0 hit=""
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] ||
    { echo "Invalid session id '$1'." >&2; return 1; }
  if [[ -f "$SESSION_DIR/$1.json" ]]; then printf '%s\n' "$1"; return 0; fi
  # No nullglob and no ${#array[@]}: an unmatched pattern stays literal and is
  # skipped by the -e test, and the counter also works on bash < 4.4 (where an
  # empty array trips "set -u")
  for f in "$SESSION_DIR/$1"*.json; do
    [[ -e "$f" ]] || continue
    n=$((n + 1)); hit="$f"
  done
  case $n in
    0) echo "No saved session matches '$1'." >&2; return 1 ;;
    1) basename "$hit" .json ;;
    *) echo "'$1' matches $n sessions; type more of the id." >&2; return 1 ;;
  esac
}

# Saves the session again if a command (/model, /provider, /reasoning, ...)
# changed its settings since the last save
sync_settings() {
  if [[ -f "$(session_file)" && "$(settings_json)" != "${LAST_SETTINGS-}" ]]
  then save_session; fi
  return 0
}

# Puts back the settings a session was saved with. $1 is "start" for a run
# that began with -c or -r: what the environment set then is kept.
restore_settings() {
  local from="$1" s p m api r t th cx ca keep_p=0 keep_m=0 keep_r=0 keep_t=0
  local keep_th=0 keep_cx=0 keep_ca=0 note="" X=$'\x1f'
  local f="$SESSION_DIR/$SESSION_ID.json"
  s=$(jq -c '.settings // empty | if type == "object" then . else empty end' \
        "$f" 2>/dev/null) || s=""
  [[ -n "$s" ]] || return 0
  IFS=$X read -r p m api r t th cx ca < <(jq -r '
    def f($k): if has($k) then (.[$k] | tostring) else "@@" end;
    [f("provider"), f("model"), f("api"), f("reasoning"),
     f("temperature"), f("thinking"), f("context"), f("compact_at")]
    | join("\u001f")' <<<"$s") || true
  if [[ "$from" == start ]]; then
    [[ -n "$PROVIDER_ENV_SET" ]] && keep_p=1
    [[ -n "$MODEL_ENV_SET" ]] && keep_m=1
    [[ -n "$REASONING_ENV_SET" ]] && keep_r=1
    [[ -n "$TEMPERATURE_ENV_SET" ]] && keep_t=1
    [[ -n "$THINKING_ENV_SET" ]] && keep_th=1
    [[ -n "$CONTEXT_ENV_SET" ]] && keep_cx=1
    [[ -n "$COMPACT_AT_ENV_SET" ]] && keep_ca=1
  fi
  if [[ "$p" != "@@" && -n "$p" && "$p" != "$PROVIDER" ]] &&
     (( ! keep_p )); then
    if resolve_provider "$p" 0; then
      if (( keep_m )); then R_MODEL="$MODEL"
      elif [[ "$m" != "@@" && -n "$m" ]]; then R_MODEL="$m"; fi
      if (( keep_r )); then R_REASONING="$REASONING"; fi
      commit_provider
      MESSAGES=$(jq -c 'map(del(.reasoning_content))' <<<"$MESSAGES")
      : >"$TMP/models"
      note+=", provider $PROVIDER"
      m="@@"
    else
      printf 'agent.sh: cannot go back to provider "%s": %s\n' \
        "$p" "$R_ERR" >&2
      printf '  staying on %s; its model and settings are not restored\n' \
        "$PROVIDER" >&2
      return 0
    fi
  fi
  if [[ "$m" != "@@" && -n "$m" ]] && (( ! keep_m )); then MODEL="$m"; fi
  # a session file is data: only values the commands would accept come back
  if [[ "$r" =~ ^(|minimal|low|medium|high)$ ]] && (( ! keep_r )); then
    REASONING="$r"
  fi
  if [[ "$t" =~ ^(|[0-9]+(\.[0-9]+)?)$ ]] && (( ! keep_t )); then
    TEMPERATURE="$t"
  fi
  if [[ "$th" =~ ^(|on|off)$ ]] && (( ! keep_th )); then THINKING="$th"; fi
  if [[ "$cx" =~ ^[0-9]+$ ]] && (( ! keep_cx )); then CONTEXT="$cx"; fi
  if [[ "$ca" == auto ]] && (( ! keep_ca )); then
    COMPACT_AT_AUTO=1
    if (( CONTEXT > 0 )); then COMPACT_AT=$(( CONTEXT * 2 ))
    else COMPACT_AT=100000; fi
  elif [[ "$ca" =~ ^[1-9][0-9]*$ ]] && (( ! keep_ca )); then
    COMPACT_AT="$ca"; COMPACT_AT_AUTO=0
  fi
  if [[ "$api" == responses ]] && ! uses_responses; then
    RESP_MODELS="$RESP_MODELS $PROVIDER/$MODEL"
  elif [[ "$api" == chat ]] && uses_responses; then
    RESP_MODELS=" $RESP_MODELS "
    RESP_MODELS=${RESP_MODELS// $PROVIDER\/$MODEL / }
  fi
  note="model $MODEL${note}"
  if uses_responses; then note+=", /responses"; fi
  if [[ -n "$REASONING" ]]; then note+=", reasoning $REASONING"; fi
  if [[ -n "$THINKING" ]]; then note+=", thinking $THINKING"; fi
  if [[ -n "$TEMPERATURE" ]]; then note+=", temperature $TEMPERATURE"; fi
  if (( CONTEXT > 0 )); then note+=", context $CONTEXT"; fi
  note+=", compacts at $COMPACT_AT bytes"
  printf '  settings: %s\n' "$note" >&2
  LAST_SETTINGS=$(settings_json)
}

# Switches to a saved session; the current one is already saved.
# $2 is "start" when this is the -c/-r of the command line.
load_session() {
  local id msgs n
  id=$(resolve_session "$1") || return 1
  # A session file that is not the shape we wrote (no "messages" array) must not
  # leave MESSAGES as "null"; refuse it instead. A missing system prompt is put
  # back so the model still knows where it is.
  msgs=$(jq -c --arg s "$SYSTEM" '
      (.messages | if type == "array" then . else empty end) | '"$REPAIR"'
      | if (.[0].role // "") == "system" then .
        else [{role: "system", content: $s}] + . end' \
    "$SESSION_DIR/$id.json" 2>/dev/null) || msgs=""
  if [[ -z "$msgs" ]]; then
    echo "Could not read session $id: no usable \"messages\" array." >&2
    return 1
  fi
  MESSAGES="$msgs"
  SESSION_ID="$id"
  # the list as saved, if it is the shape the todo tool writes
  TODOS=$(jq -c '.todos // [] | if type == "array" then
      [.[] | objects | select((.text | type) == "string")
       | {text: (.text | gsub("[\u0000-\u001f\u007f-\u009f]+"; " ")
                | .[:300]), status: (.status
          | if IN("pending", "in_progress", "done") then . else "pending"
            end)}] else [] end' "$SESSION_DIR/$id.json" 2>/dev/null) ||
    TODOS='[]'
  [[ -n "$TODOS" ]] || TODOS='[]'
  n=$(jq '[.[] | select(.role == "user")] | length' <<<"$MESSAGES")
  echo "Resumed session $SESSION_ID ($n user messages)" >&2
  restore_settings "${2:-}"
  # Remind the user where the conversation left off
  jq -r '[.[] | select(.role == "assistant" and (.content // "") != "")
          | .content] | last // empty
         | if length > 300 then .[:300] + "..." else . end' <<<"$MESSAGES" |
    sed $'s/^/\033[2m  /; s/$/\033[0m/' >&2
}

mkdir -p "$SESSION_DIR"
chmod 700 "$SESSION_DIR" 2>/dev/null || true   # also one made by an older version
if [[ -n "$RESUME" ]]; then
  if [[ "$RESUME" == last ]]; then
    RESUME=$(find_last_session) ||
      { echo "agent.sh: no saved session for $PWD" >&2; exit 1; }
  fi
  load_session "$RESUME" start || exit 1
else
  SESSION_ID="${SESSION_ID:-$(new_id)}"
  # It becomes a file name and a request header
  [[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] ||
    { echo "agent.sh: SESSION_ID may only hold letters, digits and ._-" >&2
      exit 2; }
  new_history
  (( SUB )) || about                     # banner on a fresh start
fi
apply_mode "$MODE"

# Append one JSON message and save. Everything goes through stdin, never argv:
# a single argv string is capped at 128 KiB on Linux.
append() {
  local msg="$1" out=""
  # A message we cannot add must not kill the session: warn and keep the history
  # that is already saved, so the next turn still has a valid conversation.
  if [[ -n "$msg" ]]; then
    out=$(printf '%s\n%s' "$MESSAGES" "$msg" |
          jq -cs '.[0] + [.[1]]' 2>/dev/null) || out=""
  fi
  if [[ -z "$out" ]]; then
    echo "warning: could not add a message to the session history" >&2
    return 0
  fi
  MESSAGES="$out"
  save_session
}
last_role() { jq -r '.[-1].role' <<<"$MESSAGES"; }

# ---------------------------------------------------------------- API (SSE)

# Prints content deltas as they arrive (reasoning dimmed), from SSE on stdin
show_stream() {
  jq -Rnrj --unbuffered --argjson show "$SHOW_REASONING" '
    foreach ((inputs | sub("\r$"; "")
              | select(startswith("data:")) | sub("^data: ?"; "")
              | select(. != "[DONE]") | fromjson?
              | .choices[0]?.delta? // empty), null) as $d
      ({mode: "", out: ""};
       if $d == null then      # end of stream: reset color, finish the line
         .out = (if .mode == "r" then "\u001b[0m\n"
                 elif .mode == "c" then "\n" else "" end)
       else
         .out = ""
         | if $show == 1 and (($d.reasoning_content? // "") != "") then
             .out = (if .mode != "r" then "\u001b[2m" else "" end)
                    + $d.reasoning_content | .mode = "r"
           else . end
         | if (($d.content? // "") != "") then
             .out += (if .mode == "r" then "\u001b[0m\n" else "" end)
                     + $d.content | .mode = "c"
           else . end
       end;
       .out)'
}

# Rebuilds the assistant message from the saved SSE stream. Output is one of
#   {message: {...}, streamed: true|false}   or   {error: ...}
# With $partial, an unfinished stream still yields what arrived so far.
ASSEMBLE='
  [inputs | sub("\r$"; "")] as $lines
  | [$lines[] | select(startswith("data:")) | sub("^data: ?"; "")
     | select(. != "[DONE]") | fromjson?] as $ev
  | if ($ev | length) == 0 then
      # Not SSE: an error body, or a server that ignored "stream": true
      ($lines | join("\n") | fromjson? // .) as $body
      | if ($body | type) == "object"
           and ((try $body.choices[0].message catch null) != null)
        then {message: $body.choices[0].message, streamed: false}
        else {error: (if ($body | type) == "object"
                      then ($body.error // $body) else $body end)} end
    elif any($ev[]; .error? != null) then
      {error: first($ev[] | select(.error? != null) | .error)}
    else
      (reduce ($ev[] | .choices[0]?.delta? // empty) as $d
          ({role: "assistant", content: ""};
          .content += ($d.content // "")
          | if ($d.reasoning_content // "") != "" then
              .reasoning_content = (.reasoning_content // "")
                                    + $d.reasoning_content
            else . end
          # tool calls arrive in pieces, keyed by index; arguments are
          # concatenated
          | reduce ($d.tool_calls // [])[] as $t (.;
              ($t.index // 0) as $i
              | .tool_calls[$i].id //= $t.id
              | .tool_calls[$i].type = "function"
              | .tool_calls[$i].function.name //= $t.function.name
              | .tool_calls[$i].function.arguments =
                  (.tool_calls[$i].function.arguments // "")
                  + ($t.function.arguments // ""
                     | if type == "string" then . else tojson end)))
        | if .tool_calls then .tool_calls |= map(select(. != null))
          else . end
        | if .content == "" and .tool_calls then .content = null
          else . end) as $m
      | if $partial or any($lines[]; test("^data: ?\\[DONE\\]$"))
           or any($ev[]; .choices[0]?.finish_reason? != null)
        then {message: $m, streamed: true}
        else {error: "the stream ended before the reply was complete"} end
    end'

assemble() { jq -Rn --argjson partial "${1:-false}" "$ASSEMBLE" <"$TMP/sse"; }

# One HTTP call: the request body on stdin, the SSE stream on stdout, the status
# line in $TMP/hdr
# POSTs the request body on stdin to $1
http_post() {
  local -a PKIND_HDR=()
  if [[ "$PKIND" == opencode ]]; then
    PKIND_HDR=(-H "x-opencode-session: $SESSION_ID")
  fi
  curl -sSN --connect-timeout 30 --speed-limit 1 --speed-time "$TIMEOUT" \
    -D "$TMP/hdr" "$1" \
    -H @"$TMP/auth" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    ${PKIND_HDR[@]+"${PKIND_HDR[@]}"} \
    -d @-
}

# The /responses endpoint beside $URL, if $URL ends in /chat/completions
responses_url() {
  [[ "$URL" == */chat/completions ]] || return 1
  printf '%s/responses\n' "${URL%/chat/completions}"
}

# True if the error body in $TMP/sse says the model is not served by the
# endpoint it was sent to. $1 is the HTTP code, $2 "chat" or "responses".
wrong_endpoint() {
  local code="$1" which="$2" msg
  [[ "$code" =~ ^(400|404|422)$ ]] || return 1
  msg=$(jq -r '(.error // .) | if type == "object" then (.message // "")
               elif type == "string" then . else "" end' "$TMP/sse" \
        2>/dev/null) || return 1
  if [[ "$which" == chat ]]; then
    [[ "$msg" == *"/chat/completions"* ]] &&
      [[ "$msg" == *"not accessible"* || "$msg" == *"not supported"* ||
         "$msg" == *"only supported"* || "$msg" == *"not a chat model"* ]]
  else
    [[ "$msg" == *"/responses"* || "$msg" == *"not a chat model"* ]] &&
      [[ "$msg" == *"not accessible"* || "$msg" == *"not supported"* ||
         "$msg" == *"unsupported"* || "$msg" == *"not found"* ]]
  fi
}

# The request body for the /responses API: $1 is 1 for no tools, $2 a chat
# messages array. System messages become "instructions", the rest "input".
responses_body() {
  jq -c --arg model "$MODEL" --argjson tools "$TOOLS" \
    --argjson notools "$1" --arg reasoning "$REASONING" \
    --arg temperature "$TEMPERATURE" '
    . as $m
    | {model: $model,
       instructions: ([$m[] | select(.role == "system")
                       | (.content | if type == "array"
                          then map(.text? // "") | join("") else . // "" end)]
                      | join("\n\n")),
       input: [$m[] | select(.role != "system")
         | if .role == "tool" then
             {type: "function_call_output", call_id: .tool_call_id,
              output: (.content | if type == "string" then .
                       else tojson end)}
           elif .role == "assistant" then
             (if ((.content // "") | tostring) != "" then
                {role: "assistant", content: .content} else empty end),
             ((.tool_calls // [])[]
              | {type: "function_call", call_id: .id,
                 name: .function.name, arguments: .function.arguments})
           else {role: .role, content: .content} end],
       stream: true, store: false}
    + (if $reasoning == "" then {}
       else {reasoning: {effort: $reasoning}} end)
    + (if $temperature == "" then {}
       else {temperature: ($temperature | tonumber)} end)
    + (if $notools == 1 then {}
       else {tools: [$tools[] | {type: "function", name: .function.name,
                                 description: .function.description,
                                 parameters: .function.parameters,
                                 strict: false}]} end)' <<<"$2"
}

# Turns a /responses event stream (stdin) into chat-completion chunks, so the
# rest of the agent sees one format. Anything that is not an event (a plain
# JSON error body) passes through as it is.
resp2chat() {
  jq -nRr --unbuffered '
    def chunk($d; $f): {choices: [{index: 0, delta: $d, finish_reason: $f}]};
    def line: "data: " + tojson;
    foreach inputs as $raw
      ({n: 0, map: {}, args: {}, out: [], calls: 0};
       .out = []
       | ($raw | sub("\r$"; "")) as $l
       | if $l == "" or ($l | startswith("event:")) then .
         elif ($l | startswith("data:") | not) then .out = [$l]
         else
           (try ($l | sub("^data: ?"; "") | fromjson) catch null) as $e
           | if $e == null then .
             elif $e.type == "response.output_text.delta" then
               .out = [chunk({content: $e.delta}; null) | line]
             elif ($e.type == "response.reasoning_summary_text.delta"
                   or $e.type == "response.reasoning_text.delta") then
               .out = [chunk({reasoning_content: $e.delta}; null) | line]
             elif ($e.type == "response.output_item.added"
                   and $e.item.type == "function_call") then
               .n as $i
               | .map[$e.item.id // $e.item.call_id] = $i
               | .n += 1 | .calls += 1
               | .out = [chunk({tool_calls: [{index: $i,
                   id: $e.item.call_id, type: "function",
                   function: {name: $e.item.name, arguments: ""}}]}; null)
                   | line]
             elif $e.type == "response.function_call_arguments.delta" then
               (.map[$e.item_id] // 0) as $i
               | .args[$i | tostring] = true
               | .out = [chunk({tool_calls: [{index: $i,
                   function: {arguments: $e.delta}}]}; null) | line]
             elif ($e.type == "response.output_item.done"
                   and $e.item.type == "function_call") then
               (.map[$e.item.id // $e.item.call_id] // 0) as $i
               | if .args[$i | tostring] then .
                 else .out = [chunk({tool_calls: [{index: $i,
                   function: {arguments: $e.item.arguments}}]}; null)
                   | line] end
             elif $e.type == "response.completed" then
               .out = [(chunk({}; (if .calls > 0 then "tool_calls"
                                   else "stop" end)) | line), "data: [DONE]"]
             elif $e.type == "response.incomplete" then
               .out = [(chunk({}; "length") | line), "data: [DONE]"]
             elif ($e.type == "response.failed" or $e.type == "error") then
               ($e.response.error // $e.error // $e) as $x
               | .out = [{error: {message: ($x.message // ($x | tojson))}}
                         | tojson]
             else . end
         end;
       .out[])'
}

# Sends $1 (a messages array), leaves the raw stream in $TMP/sse. $2 is a list
# of flags: "quiet" keeps the reply off the screen, otherwise it is streamed as
# it arrives; "notools" sends no tool definitions, so the reply is text.
# Retries only when nothing arrived or the server asks to retry, never after
# part of a reply was already shown. A model that /chat/completions refuses
# is tried once on /responses; if that refuses it too, the error stands.
# A /responses reply is converted to chat chunks before it lands in $TMP/sse.
request() {
  local msgs="$1" flags=" ${2:-} " attempt code body notools=0
  local pass api rurl="" first
  [[ -d "$TMP" ]] || mkdir -p "$TMP" 2>/dev/null || true
  if [[ "$PKIND" == copilot ]] && ! copilot_session; then
    # leave the reason where the reply would be, so the caller reports it
    jq -cn --arg m "$COPILOT_LAST_ERR" '{error: {message: $m}}' >"$TMP/sse"
    : >"$TMP/hdr"
    return 0
  fi
  if [[ "$PLUGIN_PROVIDERS" == *" $PROVIDER "* ]] &&
     declare -F "provider_${PROVIDER}_prepare" >/dev/null; then
    PLUGIN_ERR=""
    if ! plugin_call "provider_${PROVIDER}_prepare"; then
      jq -cn --arg m "${PLUGIN_ERR:-provider $PROVIDER could not prepare}" \
        '{error: {message: $m}}' >"$TMP/sse"
      : >"$TMP/hdr"
      return 0
    fi
    rm -f "$TMP/auth"            # the key or headers may have changed
  fi
  ensure_tmp
  if [[ "$flags" == *" notools "* ]]; then notools=1; fi
  api=chat
  if uses_responses && rurl=$(responses_url); then api=responses; fi
  first="$api"
  for pass in 1 2; do
    if [[ "$api" == chat ]]; then
      body=$(jq -c --arg model "$MODEL" --argjson tools "$TOOLS" \
        --argjson notools "$notools" --arg reasoning "$REASONING" \
        --arg thinking "$THINKING" --arg temperature "$TEMPERATURE" \
        '{model: $model}
         + (if $reasoning == "" then {} else {reasoning_effort: $reasoning} end)
         + (if $thinking == "" then {}
            else {thinking: {type: (if $thinking == "on" then "enabled"
                                     else "disabled" end)}} end)
         + (if $temperature == "" then {}
            else {temperature: ($temperature | tonumber)} end)
         + {messages: ., stream: true}
         + (if $notools == 1 then {} else {tools: $tools} end)' <<<"$msgs")
    else
      body=$(responses_body "$notools" "$msgs")
    fi
    for attempt in 1 2 3 4; do
      : >"$TMP/sse"; : >"$TMP/hdr"
      if [[ "$api" == chat ]]; then
        if [[ "$flags" == *" quiet "* ]]; then
          printf '%s' "$body" | http_post "$URL" | tee "$TMP/sse" >/dev/null \
            || true
        else
          printf '%s' "$body" | http_post "$URL" | tee "$TMP/sse" \
            | show_stream || true
        fi
      elif [[ "$flags" == *" quiet "* ]]; then
        printf '%s' "$body" | http_post "$rurl" | resp2chat \
          | tee "$TMP/sse" >/dev/null || true
      else
        printf '%s' "$body" | http_post "$rurl" | resp2chat \
          | tee "$TMP/sse" | show_stream || true
      fi
      (( INTERRUPTED )) && return 0
      code=$(awk '/^HTTP\//{c = $2} END{print c}' "$TMP/hdr")
      if [[ -s "$TMP/sse" && ! "$code" =~ ^(408|429|5[0-9][0-9])$ ]]; then
        break
      fi
      if (( attempt == 4 )); then break; fi
      printf '(request failed%s; retrying in %ss...)\n' \
        "${code:+, HTTP $code}" $((attempt * 2)) >&2
      sleep $((attempt * 2)) || true
      (( INTERRUPTED )) && return 0
    done
    if [[ "$api" == chat ]] && (( pass == 1 )) &&
       wrong_endpoint "$code" chat && rurl=$(responses_url); then
      printf '(%s is not served by /chat/completions; trying /responses)\n' \
        "$MODEL" >&2
      api=responses
      continue
    fi
    # remember a model that /responses took, so later prompts go straight there
    if [[ "$api" == responses && "$code" =~ ^2[0-9][0-9]$ ]] &&
       ! uses_responses; then
      RESP_MODELS="$RESP_MODELS $PROVIDER/$MODEL"
    elif [[ "$api" == responses ]] && wrong_endpoint "$code" responses; then
      # /responses does not take it: forget what was learned or restored
      RESP_MODELS=" $RESP_MODELS "
      RESP_MODELS=${RESP_MODELS// $PROVIDER\/$MODEL / }
      if [[ "$first" == responses ]] && (( pass == 1 )); then
        # it was only remembered as a /responses model: chat was not tried
        printf '(%s is not served by /responses; trying /chat/completions)\n' \
          "$MODEL" >&2
        api=chat
        continue
      fi
      # neither endpoint takes it: the error is shown as it is
    fi
    return 0
  done
  return 0
}

# An explorer's replies stay off the screen: only its report is printed
call_api() { if (( SUB )); then request "$MESSAGES" quiet
             else request "$MESSAGES"; fi; }

# ---------------------------------------------------------------- compacting

# What to keep when the conversation is folded into a summary
COMPACT_DEFAULT='Summarize the conversation above so that everything '
COMPACT_DEFAULT+='before it can be dropped from the context. Keep the '
COMPACT_DEFAULT+='task and its goal, the decisions and why, the files and '
COMPACT_DEFAULT+='paths involved, the commands run and what they showed, '
COMPACT_DEFAULT+='the current state, and what is left to do. Output the '
COMPACT_DEFAULT+='summary only, no preamble.'
COMPACT_ASK=$(read_prompt COMPACTION.md "$COMPACT_DEFAULT")

# Folds the conversation into a summary. Everything from the last user message
# on is kept word for word when it is at most half of COMPACT_AT, so the model
# does not lose the exact state of what it is doing; otherwise the whole
# conversation is folded. The old transcript is left next to the session file
# as <id>.json.bak. $1 = mid when called between two steps of a turn.
compact() {
  local when="${1:-}" parts msgs result summary count kept before after
  local folded
  INTERRUPTED=0            # a Ctrl-C that ended the previous turn is not ours
  count=$(jq '[.[] | select(.role != "system")] | length' <<<"$MESSAGES")
  if (( count == 0 )); then
    echo "Nothing to compact yet."
    return 1
  fi
  parts=$(jq -c --argjson max "$(( COMPACT_AT / 2 ))" "$REPAIR"'
      | ([to_entries[] | select(.value.role == "user") | .key] | last // 0)
          as $k
      | if $k > 1 and ((.[$k:] | tojson | utf8bytelength) <= $max)
        then {head: .[1:$k], tail: .[$k:]}
        else {head: .[1:], tail: []} end' <<<"$MESSAGES") || return 1
  count=$(jq '.head | length' <<<"$parts")
  kept=$(jq '.tail | length' <<<"$parts")
  msgs=$(jq -c --arg s "$SYSTEM" --arg q "$COMPACT_ASK" '
      [{role: "system", content: $s}] + .head
      + [{role: "user", content: $q}]' <<<"$parts")
  request "$msgs" "quiet notools"
  if (( INTERRUPTED )); then
    echo "Compaction interrupted; the history is unchanged." >&2
    return 1
  fi
  result=$(assemble)
  if ! summary=$(jq -er '(.message.content // "") | gsub("^\\s+|\\s+$"; "")
                         | select(. != "")' <<<"$result"); then
    printf 'Could not compact: %s\n' \
      "$(jq -r '(.error // "empty reply")
         | if type == "object" then (.message // tojson)
           else tostring end' <<<"$result")" >&2
    return 1
  fi
  before=$(printf '%s' "$MESSAGES" | wc -c)
  [[ -f "$(session_file)" ]] &&
    cp -f "$(session_file)" "$(session_file).bak" 2>/dev/null
  # Folded mid-turn with nothing kept, the history would end on the summary
  # and a failed request would then drop it as an unsent message: end on a
  # short instruction instead.
  if [[ "$TODOS" != "[]" ]]; then
    summary+=$'\n\n'"Your todo list at that point (update it with the todo"
    summary+=" tool):"$'\n'"$(todo_text)"
  fi
  folded=$(jq -c --arg s "$SYSTEM" --arg sum "$summary" --arg when "$when" '
      [{role: "system", content: $s},
       {role: "user",
        content: ("Summary of the conversation so far (everything before it "
                  + "was compacted to save context):\n\n" + $sum)}]
      + .tail
      + (if $when == "mid" and (.tail | length) == 0
         then [{role: "user", content: "Carry on with the task."}]
         else [] end)' <<<"$parts") || folded=""
  if [[ -z "$folded" ]]; then          # never swap the history for nothing
    echo "Could not compact: building the new history failed." >&2
    return 1
  fi
  MESSAGES="$folded"
  save_session
  after=$(printf '%s' "$MESSAGES" | wc -c)
  printf '(compacted %s messages into a summary, kept the last %s;' \
    "$count" "$kept"
  printf ' %s -> %s bytes)\n' "$before" "$after"
}

# Compacts on its own once the history outgrows COMPACT_AT bytes. Never fatal:
# if the summary cannot be had, the turn goes ahead with the history as it is.
auto_compact() {
  local size n
  (( AUTO_COMPACT )) || return 0
  size=$(printf '%s' "$MESSAGES" | wc -c)
  (( size > COMPACT_AT )) || return 0
  n=$(jq '[.[] | select(.role != "system")] | length' <<<"$MESSAGES" \
        2>/dev/null) || n=0
  (( n > 0 )) || return 0             # only the system prompt: nothing to fold
  printf '(history is %s bytes; compacting it first)\n' "$size" >&2
  compact "${1:-}" || printf '(compaction failed; carrying on)\n' >&2
  return 0
}

# ---------------------------------------------------------------- tools

# >>> plan guard (tests/run.sh sources the lines between these two markers)
# Plan mode may only inspect. This is a guard, not a sandbox: the command is
# split into simple commands and words the way bash would split it (quotes
# included), and it is refused unless every simple command starts with a known
# read-only program and carries none of that program's writing options.
PLAN_CMDS=(ls cat head tail wc grep egrep fgrep rg find file stat pwd echo
           printf cut tr diff comm cmp jq basename dirname readlink realpath
           du df which type uname date id ps seq nl od strings paste join
           expand unexpand fold tac rev sort tree md5sum sha1sum sha256sum
           sha512sum cksum test true false '[' '[[' ']]' : cd
           fd fdfind fzf ast-grep bat batcat)
PLAN_WORDS=()                          # filled by plan_split
PLAN_SEP=$'\n'                         # entry that ends a simple command
PLAN_NULL_RE='^>(&[12]|/dev/null)([[:space:];|&]|$)'

# Splits $1 into PLAN_WORDS, with a PLAN_SEP entry after each simple command.
# Quotes are removed, so '-delete' and "-delete" are seen as the flag they are.
# Returns 1 for anything it cannot vouch for: redirections (other than to
# /dev/null or 2>&1), command and process substitution, subshells, brace
# expansion, $'..' strings and unbalanced quotes.
plan_split() {
  local s="$1" n=${#1} i=0 c q="" w="" have=0
  PLAN_WORDS=()
  (( n <= 4000 )) || return 1
  while (( i < n )); do
    c=${s:i:1}
    if [[ "$q" == "'" ]]; then
      if [[ "$c" == "'" ]]; then q=""; else w+="$c"; fi
    elif [[ "$q" == '"' ]]; then
      case "$c" in
        '"') q="" ;;
        '`') return 1 ;;
        '$') [[ "${s:i+1:1}" == "(" ]] && return 1
             w+="$c" ;;
        "\\") i=$((i + 1)); w+="${s:i:1}" ;;
        *)   w+="$c" ;;
      esac
    else
      case "$c" in
        "'"|'"') q="$c"; have=1 ;;
        "\\")    i=$((i + 1)); w+="${s:i:1}"; have=1 ;;
        '`'|'<'|'{'|'}'|'('|')') return 1 ;;
        '$') case "${s:i+1:1}" in "("|"'"|'"') return 1 ;; esac
             w+="$c"; have=1 ;;
        '>') # only "discard" and "merge stderr" are harmless
             if [[ ( -z "$w" || "$w" == 1 || "$w" == 2 ) &&
                   "${s:i}" =~ $PLAN_NULL_RE ]]; then
               i=$((i + ${#BASH_REMATCH[1]}))
               w=""; have=0
             else
               return 1
             fi ;;
        ';'|'|'|'&'|$'\n')
             if (( have )); then PLAN_WORDS+=("$w"); fi
             w=""; have=0
             PLAN_WORDS+=("$PLAN_SEP") ;;
        ' '|$'\t')
             if (( have )); then PLAN_WORDS+=("$w"); fi
             w=""; have=0 ;;
        *)   w+="$c"; have=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  [[ -z "$q" ]] || return 1
  if (( have )); then PLAN_WORDS+=("$w"); fi
  PLAN_WORDS+=("$PLAN_SEP")
  return 0
}

# git is allowed only for subcommands that do not change the repository.
# Arguments: the words after "git".
plan_git_ok() {
  local a sub="" list=0
  # -c / --config-env can define aliases and pagers that run commands; the
  # others write a file or start a program. Some subcommands accept a long
  # option cut short (--open for --open-files-in-pager), hence the prefixes.
  for a; do
    case "$a" in
      -c|--config-env*|--output*|-O*|--op*|--ext-diff|--exec*|--upload-pack*)
        return 1 ;;
    esac
  done
  while (( $# )); do
    case "$1" in
      -C) shift; if (( $# )); then shift; fi ;;
      -*) shift ;;
      *)  sub=$1; shift; break ;;
    esac
  done
  case "$sub" in
    status|diff|log|show|blame|ls-files|ls-tree|rev-parse|grep|\
    cat-file|show-ref|shortlog|describe|for-each-ref)
      return 0 ;;
    branch|tag)
      # Listing only. A bare name creates a branch or tag unless an option
      # that implies list mode is present, so names need one of those.
      for a; do
        case "$a" in
          -l|--list|--contains*|--no-contains*|--merged*|--no-merged*|\
          --points-at*) list=1 ;;
          -n*) if [[ "$sub" == tag ]]; then list=1; else return 1; fi ;;
          -a|-r|-v|-vv|--all|--remotes|--verbose|--show-current|--sort=*|\
          --format=*|--column*|--no-column|-i|--ignore-case|--color*|\
          --no-color)
            if [[ "$sub" == tag ]]; then
              case "$a" in -a|-r|-v|-vv|--all|--remotes|--verbose) return 1 ;;
              esac
            fi ;;
          -*) return 1 ;;
        esac
      done
      for a; do
        case "$a" in
          -*) ;;
          *)  (( list )) || return 1 ;;
        esac
      done
      return 0 ;;
    remote) case "${1:-}" in ""|-v|--verbose|show|get-url) return 0 ;;
            *) return 1 ;; esac ;;
    config) case "${1:-}" in
              -l|--list|--get|--get-all|--get-regexp|--get-urlmatch) return 0 ;;
              *) return 1 ;;
            esac ;;
    stash) case "${1:-}" in list|show) return 0 ;; *) return 1 ;; esac ;;
    reflog) case "${1:-}" in ""|show) return 0 ;; *) return 1 ;; esac ;;
    worktree|submodule) case "${1:-}" in
              list|status|summary) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# One simple command, as words: the program, then its arguments
plan_simple_ok() {
  local prog="$1" a c
  shift
  case "$prog" in
    git) plan_git_ok "$@"; return ;;
    find) for a; do
            case "$a" in
              -delete|-exec|-execdir|-ok|-okdir|-fprint*|-fls) return 1 ;;
            esac
          done ;;
    sort|tree)                          # -o FILE, -oFILE, -uo FILE, --output
          for a; do                     # and sort --compress-program=PROG
            case "$a" in --o*|-[!-]*o*|-o*|--co*) return 1 ;; esac
          done ;;
    file) for a; do                     # -C writes a compiled magic file
            case "$a" in -C*|-[!-]*C*|--comp*) return 1 ;; esac
          done ;;
    date) for a; do
            case "$a" in -s*|--s*) return 1 ;; esac
          done ;;
    rg)   for a; do
            case "$a" in --pre*|--hostname-bin*) return 1 ;; esac
          done ;;
    fd|fdfind)                          # runs a program for every match
          for a; do
            case "$a" in -x|-X|--exec*|-[!-]*[xX]*) return 1 ;; esac
          done ;;
    fzf)  # without --filter it waits for a terminal; --bind and --preview
          # run programs, --listen opens a port
          c=0
          for a; do
            case "$a" in
              -f*|--filter*) c=1 ;;
              --bind*|--preview*|--listen*|--with-shell*|--history*) return 1 ;;
              --execute*|--become*) return 1 ;;
            esac
          done
          (( c )) || return 1 ;;
    ast-grep)                           # rewrites files in place
          [[ "${1:-}" != new ]] || return 1
          for a; do
            case "$a" in
              -U|--update-all|-i|--interactive|-[!-]*U*) return 1 ;;
            esac
          done ;;
    bat|batcat)                         # a pager could run a program
          for a; do
            case "$a" in --pager*|--paging=always) return 1 ;; esac
          done ;;
  esac
  for c in "${PLAN_CMDS[@]}"; do
    [[ "$c" == "$prog" ]] && return 0
  done
  return 1
}

plan_allows() {
  local w nf=0
  local -a f=()
  plan_split "$1" || return 1
  for w in "${PLAN_WORDS[@]}"; do
    if [[ "$w" == "$PLAN_SEP" ]]; then
      if (( nf > 0 )); then
        plan_simple_ok "${f[@]}" || return 1
      fi
      f=(); nf=0
    else
      f+=("$w"); nf=$((nf + 1))
    fi
  done
  return 0
}

# <<< plan guard

RISK_OK=0                  # 1 = "always" was answered for dangerous commands
GATE_OK=""                 # 1 = the user said yes at the gate

# The question that -y does not answer. $1 = the places outside the workspace
# a tool call would touch, $2 = what is dangerous about it (either may be
# empty). Returns 0 if the call may go on (GATE_OK=1 if the user said yes
# here), 1 if not, with the reason for the model in TOOL_OUT. Needs fd 9.
gate() {
  local outside="$1" risky="$2" why="" ok=""
  GATE_OK=""
  [[ -n "$outside" || -n "$risky" ]] || return 0
  if [[ -n "$outside" ]]; then
    why="it reaches outside the workspace ($WORKSPACE): $outside"
  fi
  if [[ -n "$risky" ]]; then why+="${why:+; }it is dangerous: $risky"; fi
  TOOL_OUT="Not run: $why."
  if [[ -n "$outside" && "$OUTSIDE" == deny ]]; then
    TOOL_OUT+=" Leaving the workspace is not allowed in this session; work"
    TOOL_OUT+=" inside it."
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return 1
  fi
  # An explorer never asks: several run at once and share the terminal
  if (( SUB )) || ! { true </dev/tty; } 2>/dev/null; then
    TOOL_OUT+=" It needs the user's approval and there is no terminal to"
    TOOL_OUT+=" ask on. Find another way, or tell the user what you need"
    TOOL_OUT+=" and why."
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return 1
  fi
  printf '\033[35mNeeds your approval: %s\033[0m\n' "$why" >&2
  read -rp "Allow it? [y/N/a=always this session, or say why not] " ok \
    </dev/tty || ok=""
  case "$ok" in
    [Yy]|[Yy][Ee][Ss]) GATE_OK=1 ;;
    [Aa]|[Aa]lways)
      GATE_OK=1
      if [[ -n "$outside" ]]; then
        OUTSIDE=allow
        echo "Tools may now leave the workspace without asking." >&2
      fi
      if [[ -n "$risky" ]]; then
        RISK_OK=1
        echo "Dangerous commands now run without this question." >&2
      fi ;;
    ""|[Nn]|[Nn][Oo])
      TOOL_OUT+=" The user did not allow it."
      printf '%s\n' "$TOOL_OUT" >&2
      return 1 ;;
    *)
      TOOL_OUT+=" The user did not allow it and said: $ok"
      printf '%s\n' "$TOOL_OUT" >&2
      return 1 ;;
  esac
  return 0
}

# The ordinary question, which -y (or answering "a") turns off. $1 = the
# question, $2 = what was declined ("to run this command"), $3 = what to do
# when there is no terminal. Returns 1 with TOOL_OUT set if the answer is no.
confirm() {
  local ok=""
  [[ "$AUTO" == 1 ]] && return 0
  if ! { true </dev/tty; } 2>/dev/null; then     # nothing to ask the user on
    TOOL_OUT="The user declined $2 (no terminal to ask on; $3)."
    printf '%s\n' "$TOOL_OUT" >&2
    return 1
  fi
  read -rp "$1 [y/N/a=always, or say why not] " ok </dev/tty || ok=""
  case "$ok" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Aa]|[Aa]lways)
      AUTO=1
      echo "Tool calls now run without asking (/auto to undo)." >&2
      return 0 ;;
    ""|[Nn]|[Nn][Oo])
      TOOL_OUT="The user declined $2." ;;
    *)  # anything else is the reason, passed on so the model can adjust
      TOOL_OUT="The user declined $2 and said: $ok" ;;
  esac
  printf '%s\n' "$TOOL_OUT" >&2
  return 1
}

# VIS = $1 as it is safe to show: the text comes from the model, and a control
# character in it (ESC, CR, backspace) could move the cursor and hide what the
# user is asked to approve. ESC and CR are spelled out, the others become "?".
# Newlines and tabs stay.
visible() {
  local LC_ALL=C
  VIS=$1
  [[ "$VIS" == *[$'\001'-$'\010'$'\013'-$'\037'$'\177'$'\302']* ]] || return 0
  VIS=${VIS//$'\033'/'\e'}
  VIS=${VIS//$'\r'/'\r'}
  VIS=${VIS//$'\302'[$'\200'-$'\237']/'?'}            # C1 controls in UTF-8
  VIS=${VIS//[$'\001'-$'\010'$'\013'-$'\037'$'\177']/'?'}
}

# The same for a stream: drops control characters except newline and tab
strip_controls() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

# The text of file $1 for the model, in CLIPPED: at most MAX_OUT bytes, keeping
# the head and the tail and saying what was cut
clip_file() {
  local size half
  CLIPPED=""
  [[ -f "$1" ]] || return 0            # the command removed our scratch files
  size=$(wc -c <"$1" 2>/dev/null) || return 0
  if (( size > MAX_OUT )); then
    half=$(( MAX_OUT / 2 ))
    CLIPPED=$(head -c "$half" "$1" | tr -d '\0')
    CLIPPED+=$'\n'"...[$(( size - MAX_OUT )) bytes truncated]..."$'\n'
    CLIPPED+=$(tail -c "$half" "$1" | tr -d '\0')
  else
    CLIPPED=$(tr -d '\0' <"$1")
  fi
}

# >>> outside check (tests/run.sh sources the lines between these two markers)
PATH_RE='^[]A-Za-z0-9._/~+@%*?[$-]+$'   # what a path, not a pattern, is made of
# NORM = the absolute path $1 with ".", ".." and "//" resolved by name only
# (symbolic links are not followed)
norm_path() {
  local IFS=/ part i n=0
  local -a in=() out=()
  read -ra in <<<"$1"
  for part in ${in[@]+"${in[@]}"}; do
    case "$part" in
      ""|.) ;;
      ..) if (( n > 0 )); then n=$((n - 1)); fi ;;
      *)  out[n]=$part; n=$((n + 1)) ;;
    esac
  done
  NORM=""
  for (( i = 0; i < n; i++ )); do NORM+="/${out[i]}"; done
  [[ -n "$NORM" ]] || NORM=/
}

# Prints the places command $1 names that lie outside the workspace, one per
# line. It reads the text of the command: absolute paths, ~, $HOME and paths
# that climb with "..". It cannot see what a script or program does on its
# own, a path built from other variables, or where a symbolic link leads.
outside_paths() {
  local text="$1" w p first a seen=$'\n' hit
  local -a words=()
  text=${text//'${HOME}'/$HOME}
  text=${text//'$HOME'/$HOME}
  text=${text//'${PWD}'/$START_DIR}
  text=${text//'$PWD'/$START_DIR}
  # Words: split at blanks, quotes and shell punctuation
  text=${text//[$'\n\t'\"\'\`\;\|\&\<\>\(\)=,:\{\}]/ }
  read -ra words <<<"$text"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      -[A-Za-z]/) continue ;;             # awk -F/ : a separator, not a path
      -[A-Za-z][/.~]*) w=${w:2} ;;        # -I/usr/include, -L../lib
    esac
    # shellcheck disable=SC2088  # a literal ~ in the command text
    case "$w" in
      /*)                  p=$w ;;
      "~"|"~/"*)           p="$HOME${w:1}" ;;
      ..|../*|*/..|*/../*) p="$START_DIR/$w" ;;
      *) continue ;;
    esac
    # Not a path but a pattern or an expression (sed, grep, awk)
    [[ "$p" =~ $PATH_RE ]] || continue
    norm_path "$p"
    p=$NORM
    case "$p/" in
      "${CONFIG_DIR%/}"/*) ;;            # the agent's own files: always ask
      "$WORKSPACE"/*|"$START_DIR"/*) continue ;;
      *) if [[ "$WORKSPACE" == / ]]; then continue; fi ;;
    esac
    # "/api/v1" in a grep is not a file: an absolute path counts only if its
    # first part exists (a wildcard there may match anything)
    if [[ "$w" == /* && "$p" != / ]]; then
      first=${p#/}; first="/${first%%/*}"
      if [[ "$first" != *[*?[]* && ! -e "$first" ]]; then continue; fi
    fi
    hit=1
    for a in "${OUTSIDE_ALLOW[@]}"; do
      case "$p/" in "$a"/*) hit=""; break ;; esac
    done
    [[ -n "$hit" ]] || continue
    if [[ "$seen" != *$'\n'"$p"$'\n'* ]]; then
      seen+="$p"$'\n'; printf '%s\n' "$p"
    fi
  done
}
GIT_RE='[[:space:]]git[[:space:]]+([^[:space:]]+[[:space:]]+)*'
GIT_PUSH_RE="${GIT_RE}push[[:space:]](.*[[:space:]])?"
GIT_PUSH_RE+='(--force[^[:space:]]*|--mirror|--delete|-f)[[:space:]]'
GIT_RESET_RE="${GIT_RE}reset[[:space:]](.*[[:space:]])?--hard"
GIT_CLEAN_RE="${GIT_RE}clean[[:space:]](.*[[:space:]])?-[a-zA-Z]*f"
# Prints what is dangerous about command $1, one finding per line: a program
# from ASK_CMDS in command position (sudo, dd, reboot, ...), or one of a few
# destructive forms (a forced push, a hard reset, piping a download into a
# shell). Like outside_paths it reads the text only.
risky_cmds() {
  local text="$1" seg w seen=$'\n' found
  local -a words=()
  # One simple command per line: split at ; | & ( ) ` and newlines
  text=${text//[\;\|\&\(\)\`]/$'\n'}
  while IFS= read -r seg; do
    read -ra words <<<"$seg"
    found=""
    for w in ${words[@]+"${words[@]}"}; do
      case "$w" in
        *=*|-*|[0-9]*|'{'|'!'|'$'|then|do|else|elif|if|while|until) continue ;;
        env|command|exec|nohup|time|nice|ionice|stdbuf|timeout|xargs|watch)
          continue ;;
      esac
      w=${w##*/}                          # /usr/bin/sudo
      case " $ASK_CMDS " in *" $w "*) found="$w" ;; esac
      break                               # only the word in command position
    done
    if [[ " $seg " =~ $GIT_PUSH_RE ]]; then
      found="git push that rewrites or deletes"
    elif [[ " $seg " =~ $GIT_RESET_RE ]]; then found="git reset --hard"
    elif [[ " $seg " =~ $GIT_CLEAN_RE ]]; then found="git clean -f"
    fi
    if [[ -n "$found" && "$seen" != *$'\n'"$found"$'\n'* ]]; then
      seen+="$found"$'\n'; printf '%s\n' "$found"
    fi
  done <<<"$text"
  # A download run as a program: curl ... | sh
  if [[ "$1" =~ (curl|wget)[^\;\&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh ]]
  then printf 'download piped into a shell\n'; fi
}
# True if the absolute, normalized path $1 needs no question: it is in the
# workspace or in one of the locations in OUTSIDE_ALLOW
path_is_free() {
  local a
  # The agent's own files (keys, sign-in token, plugins that run as code)
  # are never free, even when the workspace holds them
  case "$1/" in "${CONFIG_DIR%/}"/*) return 1 ;; esac
  case "$1/" in "$WORKSPACE"/*|"$START_DIR"/*) return 0 ;; esac
  if [[ "$WORKSPACE" == / ]]; then return 0; fi
  for a in "${OUTSIDE_ALLOW[@]}"; do
    case "$1/" in "$a"/*) return 0 ;; esac
  done
  return 1
}
# <<< outside check

# True if $1 would signal processes by a name that matches the agent itself, or
# every process of the user. These cannot be made harmless from the inside
# (SIGKILL cannot be caught), so they are refused with a hint instead.
SELF_KILL_RE1='(^|[^[:alnum:]_])(pkill|killall)([[:space:]]+-[^[:space:]]+)*'
SELF_KILL_RE1+='[[:space:]]+["'\'']?(ba|z|da)?sh(["'\'']|[[:space:];|&]|$)'
SELF_KILL_RE2='(^|[^[:alnum:]_])(pkill|killall)[^;|&]*agent(\.sh)?'
SELF_KILL_RE3='(^|[^[:alnum:]_])kill[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*'
SELF_KILL_RE3+='(--[[:space:]]+)?-1([[:space:];|&]|$)'
kills_agent() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ $SELF_KILL_RE1 || "$line" =~ $SELF_KILL_RE2 ]]; then
      return 0
    fi
    # "kill -9 -1" and "kill -- -1" hit everything; "kill -1 PID" is a SIGHUP
    if [[ "$line" =~ $SELF_KILL_RE3 && ! "$line" =~ kill[[:space:]]+-1[[:space:]]+[0-9$] ]]
    then return 0; fi
  done <<<"$1"
  return 1
}

# Ends the command whose process group is $1: TERM, then KILL after 2 seconds.
# (INT would do nothing: a job started in the background ignores it.)
stop_group() {
  local g="$1" i=0
  kill -TERM -- "-$g" 2>/dev/null || kill -TERM "$g" 2>/dev/null || true
  while kill -0 "$g" 2>/dev/null && (( i < 20 )); do
    sleep 0.1 || true
    i=$((i + 1))
  done
  kill -KILL -- "-$g" 2>/dev/null || true
}

# Runs one command; result goes in TOOL_OUT.
#
# The command must not be able to take the agent down with it, so it runs
# apart from us:
# - in its own session (setsid) or at least its own process group, so
#   "kill 0", a script's "trap 'kill 0' EXIT" and signals to its group stop
#   at the command; with setsid it also has no terminal to grab or garble;
# - behind a wrapper shell, so its $PPID is that wrapper and not the agent;
# - with SIGTERM to the agent held off while it runs (and reported);
# - with our scratch files and working directory put back if it removed them.
# Ctrl-C and the timeout end the whole group, background jobs included.
# (No subshell, so Ctrl-C state survives.)
run_tool() {
  # fd 9 is where the command and the notes about it are shown: our stderr, or
  # nowhere for an explorer. (A dup, not a path: opening /dev/stderr again
  # would truncate a log file that stderr was redirected to.) The command
  # itself does not get it, or its background jobs would hold our output open.
  if (( SUB )); then exec 9>/dev/null; else exec 9>&2; fi
  run_tool_body "$1"
  exec 9>&-
}

run_tool_body() {
  local cmd="$1" ok="" rc=0 out note="" tpid i=0 left=""
  local got_term=0 gone="" outside="" risky=""
  local -a run=()
  visible "$cmd"
  if (( SUB )); then
    # One dim line per command; the parent's terminal is shared with others
    printf '\033[2m[%s] $ %s\033[0m\n' "$SUB_NAME" "${VIS%%$'\n'*}" >&2
  else
    printf '\n\033[33m$ %s\033[0m\n' "$VIS" >&2
  fi
  if [[ "$MODE" == plan ]] && ! plan_allows "$cmd"; then
    TOOL_OUT="Plan mode: command not run. Only read-only inspection"
    TOOL_OUT+=" commands are allowed here"
    if (( SUB )); then TOOL_OUT+="."; else TOOL_OUT+="; /build leaves plan mode."
    fi
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return
  fi
  if kills_agent "$cmd"; then
    TOOL_OUT="Not run: this would signal processes by a name that matches the"
    TOOL_OUT+=" agent itself (or every process you own) and could end this"
    TOOL_OUT+=" session. Find the exact process (pgrep -af NAME, ps) and kill"
    TOOL_OUT+=" it by PID instead."
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return
  fi
  # Outside the workspace, or dangerous: ask every time, -y or not
  if [[ "$OUTSIDE" != allow ]]; then
    outside=$(outside_paths "$cmd" | head -n 8 | tr '\n' ' ')
    outside=${outside% }
  fi
  if (( ! RISK_OK )); then
    risky=$(risky_cmds "$cmd" | head -n 8 | tr '\n' ',')
    risky=${risky%,}; risky=${risky//,/, }
  fi
  gate "$outside" "$risky" || return 0
  if [[ -z "$GATE_OK" ]]; then
    confirm "Run it?" "to run this command" \
      "run with -y to approve commands up front" || return 0
  fi
  # A command may have removed the directory we work in or our scratch files
  ensure_tmp
  if ! cd "$START_DIR" 2>/dev/null; then
    if mkdir -p "$START_DIR" 2>/dev/null && cd "$START_DIR" 2>/dev/null; then
      gone="[note: the working directory $START_DIR had been removed; it was"
      gone+=" created again, empty]"
    else
      TOOL_OUT="Not run: the working directory $START_DIR no longer exists"
      TOOL_OUT+=" and could not be created again."
      printf '\033[31m%s\033[0m\n' "$TOOL_OUT" >&9
      return
    fi
  fi
  # Run from a file: passing the script via 'bash -c' would hit the argv limit
  # Stream output live to the terminal while saving it to a file, so partial
  # output survives Ctrl-C and huge output never has to fit in a variable.
  # The output goes through a fifo, not a pipeline, so a background job that
  # keeps the output open cannot make us wait for it.
  rm -f "$TMP/fifo" 2>/dev/null || true
  if ! printf '%s\n' "$cmd" >"$TMP/cmd.sh" || ! : >"$TMP/out" ||
     ! mkfifo "$TMP/fifo"; then
    TOOL_OUT="Not run: the agent could not write its scratch files in $TMP."
    printf '\033[31m%s\033[0m\n' "$TOOL_OUT" >&2
    return
  fi
  tee "$TMP/out" <"$TMP/fifo" >&9 2>/dev/null 9>&- &
  tpid=$!
  if [[ -n "$TIMEOUT_BIN" ]] && (( CMD_TIMEOUT > 0 )); then
    run+=("$TIMEOUT_BIN" -k 5 "$CMD_TIMEOUT")
  fi
  # No exec in the wrapper: it stays as the command's parent
  run+=(bash -c 'umask "$1"; bash "$2"' _ "$ORIG_UMASK" "$TMP/cmd.sh")
  # The main agent holds off SIGTERM while the command runs; an explorer must
  # stay stoppable by its parent, and its commands are read-only anyway.
  if (( ! SUB )); then trap 'got_term=1' TERM; fi
  if [[ -n "$SETSID_BIN" ]]; then
    "$SETSID_BIN" "${run[@]}" </dev/null >"$TMP/fifo" 2>&1 9>&- &
  else
    set -m
    "${run[@]}" </dev/null >"$TMP/fifo" 2>&1 9>&- &
    set +m
  fi
  CMD_PID=$!
  # wait returns early when a signal arrives: go back to it unless the command
  # is really gone or the user pressed Ctrl-C
  while true; do
    rc=0
    wait "$CMD_PID" 2>/dev/null || rc=$?
    kill -0 "$CMD_PID" 2>/dev/null || break
    if (( INTERRUPTED )); then
      stop_group "$CMD_PID"
      wait "$CMD_PID" 2>/dev/null || true
      break
    fi
  done
  # A timeout or Ctrl-C ends what the command left running as well; a normal
  # end leaves background jobs (a server the model started) alone
  if (( INTERRUPTED || rc == 124 )); then
    kill -TERM -- "-$CMD_PID" 2>/dev/null || true
  fi
  CMD_PID=""
  if (( ! SUB )); then trap - TERM; fi
  cd "$START_DIR" 2>/dev/null || true

  # tee ends as soon as the last writer is gone. If something the command left
  # running still holds the output after 2 seconds, stop listening to it.
  while kill -0 "$tpid" 2>/dev/null && (( i < 20 )); do
    sleep 0.1 || true
    i=$((i + 1))
  done
  if kill -0 "$tpid" 2>/dev/null; then
    kill "$tpid" 2>/dev/null || true
    left=1
  fi
  wait "$tpid" 2>/dev/null || true

  clip_file "$TMP/out"
  out="$CLIPPED"
  out="${out:-(no output)}"
  ensure_tmp
  if (( INTERRUPTED )); then
    note="[interrupted by the user]"
  elif (( rc == 124 )) && [[ -n "$TIMEOUT_BIN" ]] && (( CMD_TIMEOUT > 0 )); then
    note="[stopped: still running after ${CMD_TIMEOUT}s (CMD_TIMEOUT)]"
  elif (( rc != 0 )); then
    note="[exit code $rc]"
  fi
  if (( got_term )); then
    note+="${note:+ }[this command sent SIGTERM to the agent itself, which was"
    note+=" ignored. Never signal the agent: kill other processes by PID]"
  fi
  if [[ -n "$gone" ]]; then note+="${note:+ }$gone"; fi
  if [[ -n "$left" ]]; then
    note+="${note:+ }[a background process still had the output open; its"
    note+=" later output is not shown. Send it to a file: cmd >log 2>&1 &]"
  fi
  if [[ -n "$note" ]]; then
    out+=$'\n'"$note"
    printf '\033[31m%s\033[0m\n' "$note" >&9
  fi
  TOOL_OUT="$out"
}

# ---------------------------------------------------------------- file tools

# read, write and edit work on one file. Reading inside the workspace needs
# no question; write and edit show the change and ask like a command does.
# All three stop at the workspace like bash commands do (the gate above).

# Resolves the path $1 of a tool call. FILE_PATH = the absolute path, by name;
# FILE_OUTSIDE = that path if using it needs the gate, else empty.
file_target() {
  local p="$1" phys
  # shellcheck disable=SC2088  # a literal ~ in the tool argument
  case "$p" in
    "~"|"~/"*) p="$HOME${p:1}" ;;
    /*) ;;
    *)  p="$START_DIR/$p" ;;
  esac
  norm_path "$p"
  FILE_PATH=$NORM
  FILE_OUTSIDE=""
  [[ "$OUTSIDE" == allow ]] && return 0
  if ! path_is_free "$FILE_PATH"; then
    FILE_OUTSIDE="$FILE_PATH"
    return 0
  fi
  # Inside by name; a symbolic link may still lead out
  if [[ -L "$FILE_PATH" ]]; then
    FILE_OUTSIDE="$FILE_PATH (a symbolic link)"
    return 0
  fi
  # The nearest directory that exists: write creates the missing ones below
  # it, so a link further up must not be overlooked
  phys=${FILE_PATH%/*}
  while [[ -n "$phys" && ! -d "$phys" ]]; do phys=${phys%/*}; done
  phys=$(cd -P "${phys:-/}" 2>/dev/null && pwd -P) || phys=""
  if [[ -n "$phys" && -n "$WORKSPACE_PHYS" ]] && ! path_is_free "$phys"; then
    case "$phys/" in
      "$WORKSPACE_PHYS"/*) ;;
      *) FILE_OUTSIDE="$FILE_PATH (through a symbolic link to $phys)" ;;
    esac
  fi
  return 0
}

# True if file $1 holds a NUL byte: not text, and not safe to load in bash
is_binary() {
  local all text
  all=$(wc -c <"$1" 2>/dev/null) || return 1
  text=$(tr -d '\0' <"$1" 2>/dev/null | wc -c) || return 1
  (( all != text ))
}

# One line on the terminal saying what a file or web tool is about to do
tool_line() {
  visible "$1"
  if (( SUB )); then printf '\033[2m[%s] %s\033[0m\n' "$SUB_NAME" "$VIS" >&2
  else printf '\n\033[33m%s\033[0m\n' "$VIS" >&2; fi
}

# Shows how file $1 would change into file $2 (at most 80 lines)
show_diff() {
  command -v diff >/dev/null 2>&1 || return 0
  diff -u "$1" "$2" 2>/dev/null | tail -n +3 | head -n 80 | strip_controls |
    sed -e $'s/^+.*/\033[32m&\033[0m/' -e $'s/^-.*/\033[31m&\033[0m/' >&2 ||
    true
}

# read {path, offset?, limit?}: the file with line numbers
tool_read() {
  local path off lim total last
  path=$(jq -r '.path? // empty | strings' <<<"$1")
  off=$(jq -r '(.offset? // 1) | tonumber? // 1 | floor' <<<"$1") || off=1
  lim=$(jq -r --argjson d "$READ_LINES" \
          '(.limit? // $d) | tonumber? // $d | floor' <<<"$1") || lim=$READ_LINES
  (( off >= 1 )) || off=1
  (( lim >= 1 )) || lim=$READ_LINES
  if [[ -z "$path" ]]; then
    TOOL_OUT='Error: invalid tool arguments; expected JSON like {"path": "..."}.'
    return 0
  fi
  file_target "$path"
  if (( off > 1 )); then tool_line "read $path (from line $off)"
  else tool_line "read $path"; fi
  gate "$FILE_OUTSIDE" "" || return 0
  if [[ -d "$FILE_PATH" ]]; then
    TOOL_OUT="Error: $path is a directory. List it with bash: ls -la $path"
  elif [[ ! -e "$FILE_PATH" ]]; then
    TOOL_OUT="Error: no such file: $path (looked for $FILE_PATH)"
  elif [[ ! -r "$FILE_PATH" ]]; then
    TOOL_OUT="Error: $path cannot be read (permission denied)."
  elif is_binary "$FILE_PATH"; then
    TOOL_OUT="$path is a binary file ($(wc -c <"$FILE_PATH" | tr -d ' ')"
    TOOL_OUT+=" bytes); its content is not shown."
  else
    total=$(awk 'END { print NR }' "$FILE_PATH" 2>/dev/null) || total=0
    if (( total == 0 )); then
      TOOL_OUT="($path is empty)"
    elif (( off > total )); then
      TOOL_OUT="($path has only $total lines)"
    else
      awk -v s="$off" -v n="$lim" '
        NR >= s + n { exit }
        NR >= s     { printf "%6d\t%s\n", NR, $0 }' "$FILE_PATH" \
        >"$TMP/read.out" 2>/dev/null || true
      clip_file "$TMP/read.out"
      TOOL_OUT="$CLIPPED"
      last=$((off + lim - 1))
      if (( last < total )); then
        TOOL_OUT+=$'\n'"[lines $off-$last of $total; read on with offset"
        TOOL_OUT+=" $((last + 1))]"
      fi
    fi
  fi
  return 0
}

# The checks write and edit share. Returns 1 with TOOL_OUT set if the file
# must not be changed.
may_change() {
  if (( SUB )) || [[ "$MODE" == plan ]]; then
    TOOL_OUT="Plan mode: file not changed. Only reading is allowed here"
    if (( SUB )); then TOOL_OUT+="."; else TOOL_OUT+="; /build leaves plan mode."
    fi
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
    return 1
  fi
  if [[ -d "$FILE_PATH" ]]; then
    TOOL_OUT="Error: $FILE_PATH is a directory."
    return 1
  fi
  return 0
}

# Puts file $1 in place as FILE_PATH, with the user's own umask. An existing
# file keeps its permissions (it is overwritten, not replaced).
put_file() {
  local err
  if ! err=$( { umask "$ORIG_UMASK"
                mkdir -p "${FILE_PATH%/*}" && cat "$1" >"$FILE_PATH"; } 2>&1 )
  then
    TOOL_OUT="Error: could not write $FILE_PATH: ${err:-unknown error}"
    return 1
  fi
  return 0
}

# write {path, content}: creates the file or replaces all of it
tool_write() {
  local path lines
  path=$(jq -r '.path? // empty | strings' <<<"$1")
  if [[ -z "$path" ]] || ! jq -e '.content? | type == "string"' <<<"$1" \
       >/dev/null 2>&1; then
    TOOL_OUT='Error: invalid tool arguments; expected JSON like'
    TOOL_OUT+=' {"path": "...", "content": "..."}.'
    return 0
  fi
  jq -j '.content' <<<"$1" >"$TMP/arg.content"
  file_target "$path"
  lines=$(awk 'END { print NR }' "$TMP/arg.content")
  if [[ -e "$FILE_PATH" ]]; then tool_line "write $path ($lines lines, replaces it)"
  else tool_line "write $path ($lines lines, new file)"; fi
  may_change || return 0
  gate "$FILE_OUTSIDE" "" || return 0
  if (( ! SUB )); then
    if [[ -f "$FILE_PATH" ]] && ! is_binary "$FILE_PATH"; then
      show_diff "$FILE_PATH" "$TMP/arg.content"
    else
      head -n 20 "$TMP/arg.content" | strip_controls |
        sed $'s/^.*$/\033[32m+&\033[0m/' >&2
      if (( lines > 20 )); then printf '  ... %s more lines\n' $((lines - 20)) >&2
      fi
    fi
  fi
  if [[ -z "$GATE_OK" ]]; then
    confirm "Write it?" "to write this file" \
      "run with -y to approve changes up front" || return 0
  fi
  put_file "$TMP/arg.content" || return 0
  TOOL_OUT="Wrote $path ($lines lines)."
  return 0
}

# edit {path, old, new, replace_all?}: replaces text that must match exactly
tool_edit() {
  local path all content old new rest count
  path=$(jq -r '.path? // empty | strings' <<<"$1")
  all=$(jq -r '.replace_all? == true' <<<"$1")
  if [[ -z "$path" ]] ||
     ! jq -e '(.old? | type == "string") and (.new? | type == "string")' \
       <<<"$1" >/dev/null 2>&1; then
    TOOL_OUT='Error: invalid tool arguments; expected JSON like'
    TOOL_OUT+=' {"path": "...", "old": "...", "new": "..."}.'
    return 0
  fi
  jq -j '.old' <<<"$1" >"$TMP/arg.old"
  jq -j '.new' <<<"$1" >"$TMP/arg.new"
  file_target "$path"
  tool_line "edit $path"
  may_change || return 0
  gate "$FILE_OUTSIDE" "" || return 0
  if [[ ! -f "$FILE_PATH" ]]; then
    TOOL_OUT="Error: no such file: $path. Use write to create a file."
    return 0
  fi
  if is_binary "$FILE_PATH"; then
    TOOL_OUT="Error: $path is a binary file; edit cannot change it."
    return 0
  fi
  # read -d '' takes the whole file, trailing newlines included (a plain
  # $(...) would drop them)
  IFS= read -r -d '' content <"$FILE_PATH" || true
  IFS= read -r -d '' old <"$TMP/arg.old" || true
  IFS= read -r -d '' new <"$TMP/arg.new" || true
  if [[ -z "$old" ]]; then
    TOOL_OUT="Error: old is empty. Give the exact text to replace, or use"
    TOOL_OUT+=" write to replace the whole file."
    return 0
  fi
  if [[ "$old" == "$new" ]]; then
    TOOL_OUT="Error: old and new are the same; nothing to change."
    return 0
  fi
  rest=${content//"$old"/}
  count=$(( (${#content} - ${#rest}) / ${#old} ))
  if (( count == 0 )); then
    TOOL_OUT="Error: old was not found in $path. It must match the file"
    TOOL_OUT+=" exactly, including spaces, tabs and line breaks. Read the"
    TOOL_OUT+=" lines again and copy them without the line numbers."
    return 0
  fi
  if (( count > 1 )) && [[ "$all" != true ]]; then
    TOOL_OUT="Error: old matches $count places in $path. Add surrounding"
    TOOL_OUT+=" lines to old until it matches one place, or set replace_all"
    TOOL_OUT+=" to true to change them all."
    return 0
  fi
  if [[ "$all" == true ]]; then content=${content//"$old"/"$new"}
  else content=${content/"$old"/"$new"}; fi
  printf '%s' "$content" >"$TMP/edit.new"
  show_diff "$FILE_PATH" "$TMP/edit.new"
  if [[ -z "$GATE_OK" ]]; then
    confirm "Apply it?" "to make this change" \
      "run with -y to approve changes up front" || return 0
  fi
  put_file "$TMP/edit.new" || return 0
  if (( count == 1 )); then TOOL_OUT="Edited $path."
  else TOOL_OUT="Edited $path: $count replacements."; fi
  return 0
}

# ---------------------------------------------------------------- web tools

# Turns the HTML in file $1 into plain text on stdout. A text browser does it
# best; without one, a small awk filter drops scripts, styles and tags.
html_to_text() {
  if command -v w3m >/dev/null 2>&1; then
    w3m -dump -T text/html -cols 100 <"$1" 2>/dev/null && return 0
  fi
  if command -v lynx >/dev/null 2>&1; then
    lynx -dump -stdin -nolist -width=100 <"$1" 2>/dev/null && return 0
  fi
  tr '\n\r\t' '   ' <"$1" | sed 's/</\
</g' | awk '
    function flush() {
      gsub(/&nbsp;/, " ", buf); gsub(/&lt;/, "<", buf); gsub(/&gt;/, ">", buf)
      gsub(/&quot;/, "\"", buf); gsub(/&#39;|&apos;/, "\047", buf)
      gsub(/&amp;/, "\\&", buf); gsub(/[ ]+/, " ", buf); sub(/^ /, "", buf)
      if (buf != "") print buf
      buf = ""
    }
    {
      line = $0
      if (comment) {
        i = index(line, "-->")
        if (!i) next
        comment = 0; buf = buf substr(line, i + 3); next
      }
      if (substr(line, 1, 1) != "<") { buf = buf line; next }
      if (substr(line, 1, 4) == "<!--") {
        i = index(line, "-->")
        if (i) buf = buf substr(line, i + 3); else comment = 1
        next
      }
      gt = index(line, ">")
      if (!gt) next
      tag = tolower(substr(line, 2, gt - 2)); text = substr(line, gt + 1)
      closing = (substr(tag, 1, 1) == "/")
      name = closing ? substr(tag, 2) : tag
      sub(/[ \/].*/, "", name)
      if (skip != "") { if (closing && name == skip) skip = ""; next }
      if (name ~ /^(script|style|noscript|svg|template)$/) {
        if (!closing && tag !~ /\/$/) skip = name
        next
      }
      if (name ~ /^(p|div|br|li|tr|h[1-6]|section|article|header|footer|ul|ol|pre|blockquote|table|title|hr|dt|dd)$/) {
        flush()
        if (!closing && name ~ /^h[1-6]$/) buf = "# "
        if (!closing && name == "li") buf = "- "
      }
      buf = buf text
    }
    END { flush() }'
}

# web_fetch {url}: the page as text
tool_web_fetch() {
  local url meta code ctype
  url=$(jq -r '.url? // empty | strings' <<<"$1")
  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    TOOL_OUT='Error: invalid tool arguments; expected JSON like'
    TOOL_OUT+=' {"url": "https://..."} (http and https only).'
    return 0
  fi
  tool_line "web_fetch $url"
  confirm "Fetch it?" "to fetch this page" \
    "run with -y to approve up front" || return 0
  : >"$TMP/web.body"
  meta=$(curl -sSL --max-time "$WEB_TIMEOUT" --max-filesize 5000000 \
           --proto '=http,https' --proto-redir '=http,https' \
           -A "agent.sh/$VERSION" -o "$TMP/web.body" \
           -w '%{http_code} %{content_type}' "$url" 2>"$TMP/web.err") || {
    TOOL_OUT="Error: could not fetch $url: $(head -c 300 "$TMP/web.err")"
    return 0
  }
  code=${meta%% *}; ctype=${meta#* }
  case "$ctype" in
    *html*|"")
      html_to_text "$TMP/web.body" 2>/dev/null | cat -s >"$TMP/web.txt" ;;
    text/*|*json*|*xml*|*javascript*|*yaml*|*toml*)
      tr -d '\0' <"$TMP/web.body" >"$TMP/web.txt" ;;
    *)
      TOOL_OUT="$url is not text ($ctype,"
      TOOL_OUT+=" $(wc -c <"$TMP/web.body" | tr -d ' ') bytes); not shown."
      return 0 ;;
  esac
  clip_file "$TMP/web.txt"
  TOOL_OUT="${CLIPPED:-(the page has no text)}"
  if [[ "$code" != 2* ]]; then
    TOOL_OUT="[HTTP $code]"$'\n'"$TOOL_OUT"
  fi
  return 0
}

# Decodes %XX and + in $1 (a URL query value) to stdout
url_decode() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }

# Reads a DuckDuckGo HTML result page in file $1; prints title, URL and
# snippet, one tab-separated result per line
ddg_parse() {
  local line href title n=0
  while IFS= read -r line; do
    case "$line" in
      *result__a*)
        href=$(sed -n 's/.*href="\([^"]*\)".*/\1/p' <<<"$line")
        title=$(sed -e 's/^[^>]*>//' -e 's/<\/a>.*//' -e 's/<[^>]*>//g' \
                  <<<"$line" | tr -s ' ')
        title=${title% }
        case "$href" in
          *uddg=*) href=${href#*uddg=}; href=${href%%&*}
                   href=$(url_decode "$href") ;;
          //*)     href="https:$href" ;;
        esac
        (( n == 0 )) || printf '\n'
        n=$((n + 1))
        printf '%s\t%s\t' "$title" "$href" ;;
      *result__snippet*)
        (( n > 0 )) || continue
        sed -e 's/^[^>]*>//' -e 's/<\/a>.*//' -e 's/<[^>]*>//g' <<<"$line" |
          tr -s ' ' | tr -d '\n' ;;
    esac
  done < <(tr '\n\r' '  ' <"$1" | sed 's/<a /\
<a /g')
  (( n == 0 )) || printf '\n'
}

# web_search {query, count?}: titles, URLs and snippets. The backend is the
# first that is configured: Brave, Tavily, a SearXNG server, else the
# DuckDuckGo HTML page (no key, but it may refuse automated requests).
tool_web_search() {
  local query count q via rows
  query=$(jq -r '.query? // empty | strings' <<<"$1")
  count=$(jq -r '(.count? // 5) | tonumber? // 5 | floor' <<<"$1") || count=5
  (( count >= 1 && count <= 10 )) || count=5
  if [[ -z "${query//[[:space:]]/}" ]]; then
    TOOL_OUT='Error: invalid tool arguments; expected JSON like'
    TOOL_OUT+=' {"query": "..."}.'
    return 0
  fi
  tool_line "web_search $query"
  confirm "Search for it?" "to run this search" \
    "run with -y to approve up front" || return 0
  q=$(jq -rn --arg q "$query" '$q | @uri')
  : >"$TMP/web.body"; : >"$TMP/web.err"
  if [[ -n "$BRAVE_KEY" ]]; then
    via="Brave"
    printf 'X-Subscription-Token: %s\n' "$BRAVE_KEY" >"$TMP/web.hdr"
    curl -sS --max-time "$WEB_TIMEOUT" -H @"$TMP/web.hdr" \
      -H 'Accept: application/json' -o "$TMP/web.body" \
      "$BRAVE_URL?q=$q&count=$count" 2>"$TMP/web.err" || true
    rows=$(jq -r '.web.results[]? | [.title, .url, (.description // "")]
                  | map(gsub("<[^>]*>"; "") | gsub("\\s+"; " ")) | @tsv' \
             "$TMP/web.body" 2>/dev/null) || rows=""
  elif [[ -n "$TAVILY_KEY" ]]; then
    via="Tavily"
    printf 'Authorization: Bearer %s\n' "$TAVILY_KEY" >"$TMP/web.hdr"
    jq -cn --arg q "$query" --argjson n "$count" \
      '{query: $q, max_results: $n}' |
      curl -sS --max-time "$WEB_TIMEOUT" -H @"$TMP/web.hdr" \
        -H 'Content-Type: application/json' -o "$TMP/web.body" -d @- \
        "$TAVILY_URL" 2>"$TMP/web.err" || true
    rows=$(jq -r '.results[]? | [.title, .url, (.content // "")]
                  | map(gsub("\\s+"; " ")) | @tsv' \
             "$TMP/web.body" 2>/dev/null) || rows=""
  elif [[ -n "$SEARXNG_URL" ]]; then
    via="SearXNG"
    curl -sS --max-time "$WEB_TIMEOUT" -o "$TMP/web.body" \
      "${SEARXNG_URL%/}/search?q=$q&format=json" 2>"$TMP/web.err" || true
    rows=$(jq -r '.results[]? | [.title, .url, (.content // "")]
                  | map(gsub("\\s+"; " ")) | @tsv' \
             "$TMP/web.body" 2>/dev/null) || rows=""
  else
    via="DuckDuckGo"
    curl -sSL --max-time "$WEB_TIMEOUT" -o "$TMP/web.body" \
      -A 'Mozilla/5.0 (X11; Linux x86_64) agent.sh' \
      "$DDG_URL?q=$q" 2>"$TMP/web.err" || true
    rows=$(ddg_parse "$TMP/web.body" 2>/dev/null) || rows=""
  fi
  rm -f "$TMP/web.hdr"
  if [[ -z "$rows" ]]; then
    TOOL_OUT="No results from $via for: $query."
    if [[ -s "$TMP/web.err" ]]; then
      TOOL_OUT+=" ($(head -c 200 "$TMP/web.err" | tr '\n' ' '))"
    fi
    if [[ "$via" == DuckDuckGo ]]; then
      TOOL_OUT+=" The keyless search may have refused the request; the user"
      TOOL_OUT+=" can set BRAVE_API_KEY, TAVILY_API_KEY or SEARXNG_URL."
    fi
    return 0
  fi
  TOOL_OUT=$(head -n "$count" <<<"$rows" |
    awk -F'\t' '{ printf "%d. %s\n   %s\n", NR, $1, $2
                  if ($3 != "") printf "   %s\n", $3 }')
  return 0
}

# Runs file or web tool $1 with the arguments $2 (a JSON object); the result
# goes in TOOL_OUT. fd 9 is the terminal, or nowhere for an explorer.
other_tool() {
  if (( SUB )); then exec 9>/dev/null; else exec 9>&2; fi
  ensure_tmp
  TOOL_OUT=""
  if [[ ", $PLUGIN_TOOLS_NAMES, " == *", $1, "* ]]; then
    plugin_tool_run "$1" "$2"
  else
    "tool_$1" "$2" || true
  fi
  exec 9>&-
  [[ -n "$TOOL_OUT" ]] || TOOL_OUT="(no output)"
}

# ---------------------------------------------------------------- todo list

# The model's plan for a longer task: a list of {text, status} it rewrites
# whole with the todo tool. It is shown as it changes, saved with the
# session and carried through compaction. /todo shows it. TODOS is set at
# the top, before a resumed session fills it.

# The list as text: [x] done, [>] in progress, [ ] pending
todo_text() {
  jq -r '.[] | (if .status == "done" then "[x] "
                elif .status == "in_progress" then "[>] "
                else "[ ] " end) + .text' <<<"$TODOS"
}

# The list on the screen, the item in progress in bold, done ones dim
todo_show() {
  local n
  n=$(jq length <<<"$TODOS")
  if (( n == 0 )); then echo "The todo list is empty."; return 0; fi
  jq -r '.[] | if .status == "done" then "\u001b[2m  [x] " + .text
               elif .status == "in_progress" then "\u001b[1m  [>] " + .text
               else "  [ ] " + .text end + "\u001b[0m"' <<<"$TODOS"
}

# todo {items: [{text, status}]}: replaces the list
tool_todo() {
  local list err n done_n
  err=$(jq -r '
    if (.items | type) != "array" then "items must be an array"
    elif (.items | length) > 50 then "at most 50 items"
    elif any(.items[]; (type != "object") or ((.text | type) != "string")
             or ((.text | gsub("\\s"; "")) == "")) then
      "every item needs a non-empty text"
    elif any(.items[]; (.status // "pending")
             | IN("pending", "in_progress", "done") | not) then
      "status must be pending, in_progress or done"
    else empty end' <<<"$1" 2>/dev/null) || err="the arguments are not JSON"
  if [[ -n "$err" ]]; then
    TOOL_OUT="Error: $err. Expected JSON like {\"items\": [{\"text\": "
    TOOL_OUT+="\"...\", \"status\": \"pending|in_progress|done\"}]}."
    return 0
  fi
  # no control characters: an item is printed as it is
  list=$(jq -c '[.items[] | {text: (.text
                                     | gsub("[\u0000-\u001f\u007f-\u009f]+";
                                            " ") | .[:300]),
                             status: (.status // "pending")}]' <<<"$1")
  TODOS="$list"
  save_session
  n=$(jq length <<<"$TODOS")
  done_n=$(jq '[.[] | select(.status == "done")] | length' <<<"$TODOS")
  if (( SUB )); then :
  else
    printf '\n\033[33mtodo (%s of %s done)\033[0m\n' "$done_n" "$n" >&2
    todo_show >&2
  fi
  TOOL_OUT="Todo list updated ($done_n of $n done):"$'\n'"$(todo_text)"
  if (( n == 0 )); then TOOL_OUT="Todo list cleared."; fi
}

# ---------------------------------------------------------------- explorers

# An explorer is this script again, started with AGENT_SUB=1: plan mode (the
# harness refuses anything but read-only commands), no questions, no explore
# tool of its own, a throwaway session, and only its final message on stdout.
# The parent starts the explore calls of one reply together, at most SUB_MAX
# at a time, and hands each report back as that call's tool result.
SUB_DIR="$TMP/sub"
SUB_PIDS=()                # pid by call number
SUB_T0=()                  # start time by call number
SUB_QUEUE=()               # call numbers still to start
SUB_QPOS=0
SUB_RUNNING=0

sub_kill_all() {
  local pid
  for pid in ${SUB_PIDS[@]+"${SUB_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  SUB_QPOS=${#SUB_QUEUE[@]}              # and start no more
}

# Starts explorer number $1 on the task in $SUB_DIR/$1.task
sub_start() {
  local n="$1" task line
  task=$(cat "$SUB_DIR/$n.task")
  if [[ "$PKIND" == copilot ]]; then
    copilot_session $((SUB_TIMEOUT + 60)) || true   # an explorer cannot renew
  fi
  line=${task%%$'\n'*}
  if (( ${#line} > 100 )); then line="${line:0:100}..."; fi
  printf '\033[33m[explorer %s] %s\033[0m\n' "$n" "$line" >&2
  (
    umask "$ORIG_UMASK"
    # The key and the settings of this run go by environment, not argv
    export AGENT_SUB=1 AGENT_SUB_NAME="explorer $n" AGENT_API_KEY="$API_KEY"
    export AGENT_RESPONSES_MODELS="$RESP_MODELS"
    export MODEL PROVIDER URL REASONING THINKING TEMPERATURE MAX_OUT TIMEOUT
    export CMD_TIMEOUT SUB_MAX_STEPS PROJECT_DOC AUTO_COMPACT COMPACT_AT
    export OUTSIDE WORKSPACE ALLOW_PATHS ASK_CMDS READ_LINES
    export SESSION_DIR="$SUB_DIR/sessions" AGENT_HISTFILE=/dev/null
    export SHOW_REASONING=0
    if [[ -n "$PROMPT_DIR" ]]; then export PROMPT_DIR; fi
    if [[ -n "$TIMEOUT_BIN" ]] && (( SUB_TIMEOUT > 0 )); then
      exec "$TIMEOUT_BIN" -k 5 "$SUB_TIMEOUT" "$SELF" -- "Task: $task"
    fi
    exec "$SELF" -- "Task: $task"
  ) </dev/null >"$SUB_DIR/$n.out" 2> >(tee "$SUB_DIR/$n.err" >&2) &
  SUB_PIDS[n]=$!
  SUB_T0[n]=$SECONDS
  SUB_RUNNING=$((SUB_RUNNING + 1))
}

# Starts queued explorers while fewer than SUB_MAX are running
sub_fill() {
  while (( SUB_RUNNING < SUB_MAX && SUB_QPOS < ${#SUB_QUEUE[@]} )); do
    sub_start "${SUB_QUEUE[SUB_QPOS]}"
    SUB_QPOS=$((SUB_QPOS + 1))
  done
}

# Waits for explorer $1; its report (or what went wrong) goes in TOOL_OUT
sub_collect() {
  local n="$1" pid rc=0 took why
  pid=${SUB_PIDS[n]:-}
  if [[ -z "$pid" ]]; then               # never started: the turn was stopped
    TOOL_OUT="Skipped: the user interrupted."
    return
  fi
  wait "$pid" 2>/dev/null || rc=$?
  if (( INTERRUPTED )); then             # Ctrl-C ends the wait, not the child
    sub_kill_all
    wait "$pid" 2>/dev/null || true
    TOOL_OUT="Explorer stopped: the user interrupted."
    return
  fi
  SUB_RUNNING=$((SUB_RUNNING - 1))
  took=$((SECONDS - ${SUB_T0[n]:-$SECONDS}))
  clip_file "$SUB_DIR/$n.out"
  if (( rc == 0 )) && [[ -n "${CLIPPED//[[:space:]]/}" ]]; then
    TOOL_OUT="$CLIPPED"
    printf '\033[33m[explorer %s] done in %ss\033[0m\n' "$n" "$took" >&2
    printf '\033[2m%s\033[0m\n' "$CLIPPED" >&2
  else
    if (( rc == 124 )) && [[ -n "$TIMEOUT_BIN" ]] && (( SUB_TIMEOUT > 0 )); then
      why="it was stopped after ${SUB_TIMEOUT}s (SUB_TIMEOUT)"
    elif (( rc == 0 )); then
      why="it returned no report"
    else
      why="exit code $rc: $(tail -n 3 "$SUB_DIR/$n.err" 2>/dev/null |
                            tr -d '\0' | sed $'s/\033\\[[0-9;]*m//g' |
                            tr '\n' ' ')"
    fi
    TOOL_OUT="The explorer failed: $why"
    if [[ -n "${CLIPPED//[[:space:]]/}" ]]; then
      TOOL_OUT+=$'\n'"What it printed before that:"$'\n'"$CLIPPED"
    fi
    printf '\033[31m[explorer %s] failed: %s\033[0m\n' "$n" "$why" >&2
  fi
}

# ---------------------------------------------------------------- turn loop

# Keep history valid after a failed request
abort_turn() {
  case "$(last_role)" in
    user) MESSAGES=$(jq -c '.[:-1]' <<<"$MESSAGES"); save_session
          echo "(message not sent — press Up to retry)" >&2 ;;
    tool) append '{"role": "assistant",
                  "content": "(request failed; turn aborted)"}' ;;
  esac
}

# The arguments of a tool call as an object: normally a JSON *string*, but some
# backends send an object
ARG='(.function.arguments | if type == "string" then fromjson? else . end)'

# One user turn: call the model, run its tools, repeat until it stops.
# TURN_OK is 0 afterwards if the turn failed or was interrupted.
TURN_OK=1
run_turn() {
  local result msg call id name cmd out n ncalls steps=0 args errtext blocked
  TURN_OK=1
  while true; do
    INTERRUPTED=0
    call_api

    if (( INTERRUPTED )); then
      printf '\033[0m\n(interrupted)\n' >&2
      # Keep whatever text was already shown; drop half-written tool calls
      msg=$(assemble true |
            jq -c '.message // empty
                   | select((.content // "") != "")
                   | {role,
                      content: (.content + "\n[interrupted by the user]")}')
      if [[ -n "$msg" ]]; then append "$msg"; else abort_turn; fi
      TURN_OK=0
      return
    fi

    result=$(assemble)
    if ! msg=$(jq -ce '.message // empty' <<<"$result"); then
      echo "API error:" >&2
      errtext=$(jq -r '(.error // "(no response)")
             | if type == "object" then (.message // tojson) else . end
             | if . == "" then "(no response)" else . end' <<<"$result")
      printf '%s\n' "$errtext" >&2
      abort_turn
      TURN_OK=0
      return
    fi

    # Save the whole assistant message (keeps tool_calls and any
    # reasoning_content)
    append "$msg"
    # No tool calls -> the model is done with this turn
    ncalls=$(jq '.tool_calls // [] | length' <<<"$msg")
    # Streamed text is already on screen; a non-streamed reply is not. An
    # explorer prints nothing but its final message: that is its report.
    if (( SUB )); then
      (( ncalls > 0 )) || jq -r '.content // empty' <<<"$msg"
    elif [[ "$(jq -r '.streamed' <<<"$result")" != true ]]; then
      jq -r '.content // empty' <<<"$msg"
    fi
    (( ncalls > 0 )) || return 0

    # Explorers first: they work in the background while the other calls of
    # this reply run, and each is collected at its place in the order
    SUB_PIDS=(); SUB_T0=(); SUB_QUEUE=(); SUB_QPOS=0; SUB_RUNNING=0
    if (( SUBAGENTS )); then
      mkdir -p "$SUB_DIR"
      n=0
      while IFS= read -r call; do
        n=$((n + 1))
        [[ "$(jq -r '.function.name' <<<"$call")" == explore ]] || continue
        jq -r "$ARG"' | .task? // empty' <<<"$call" >"$SUB_DIR/$n.task"
        if [[ -n "$(tr -d '[:space:]' <"$SUB_DIR/$n.task")" ]]; then
          SUB_QUEUE+=("$n")
        fi
      done < <(jq -c '.tool_calls[]' <<<"$msg")
      sub_fill
    fi

    n=0
    while IFS= read -r call; do
      n=$((n + 1))
      id=$(jq -r '.id' <<<"$call")
      name=$(jq -r '.function.name' <<<"$call")
      cmd=$(jq -r "$ARG"' | .command? // empty' <<<"$call")
      args=$(jq -c "$ARG"' | objects // {}' <<<"$call" 2>/dev/null) || args='{}'
      [[ -n "$args" ]] || args='{}'
      if (( INTERRUPTED )); then
        sub_kill_all
        out="Skipped: the user interrupted."
      elif [[ "$name" == explore ]] && (( SUBAGENTS )); then
        if [[ -n "${SUB_PIDS[n]:-}" ]]; then
          sub_collect "$n"
          out="$TOOL_OUT"
          sub_fill                        # a slot is free: start the next one
        else
          out='Error: invalid tool arguments; expected JSON like'
          out+=' {"task": "..."}.'
          printf '%s\n' "$out" >&2
        fi
      elif [[ ", $TOOL_NAMES, " != *", $name, "* ]]; then
        out="Error: unknown tool '$name'. The tools are: $TOOL_NAMES."
        printf '%s\n' "$out" >&2
      elif ! blocked=$(plugin_tool_allowed "$name" "$args" 9>&2); then
        out="Not run: a plugin blocked this call"
        out+="${blocked:+: $blocked}."
        printf '\033[33m%s\033[0m\n' "$out" >&2
      elif [[ "$name" != bash ]]; then      # read, write, edit, web_*
        other_tool "$name" "$args"
        out="$TOOL_OUT"
      elif [[ -z "$cmd" ]]; then
        out='Error: invalid tool arguments; expected JSON like'
        out+=' {"command": "..."}.'
        printf '%s\n' "$out" >&2
      else
        run_tool "$cmd"
        out="$TOOL_OUT"
      fi
      # Each result is its own message with role "tool"
      append "$(printf '%s' "$out" |
        jq -cRs --arg id "$id" \
           '{role: "tool", tool_call_id: $id, content: .}')"
    done < <(jq -c '.tool_calls[]' <<<"$msg")

    if (( INTERRUPTED )); then
      echo "(turn stopped — tell the agent what to do next)" >&2
      TURN_OK=0
      return
    fi
    # A long turn can outgrow the context on tool output alone
    auto_compact mid >&2
    if (( INTERRUPTED )); then TURN_OK=0; return; fi

    # Out of steps: one last request without tools, so the turn ends with an
    # answer built on what was found instead of being cut off
    steps=$((steps + 1))
    if (( MAX_STEPS > 0 && steps >= MAX_STEPS )); then
      append "$(jq -cn --arg n "$MAX_STEPS" '{role: "user", content:
        ("You have used all \($n) tool steps of this turn. Do not call "
         + "tools again: give your final answer now from what you found, "
         + "and say what is still open.")}')"
      if (( SUB )); then request "$MESSAGES" "quiet notools"
      else request "$MESSAGES" notools; fi
      if (( INTERRUPTED )); then abort_turn; TURN_OK=0; return; fi
      result=$(assemble)
      if ! msg=$(jq -ce '.message // empty | del(.tool_calls)' <<<"$result")
      then
        echo "API error: no final answer after the step limit." >&2
        abort_turn; TURN_OK=0
        return
      fi
      append "$msg"
      if (( SUB )) || [[ "$(jq -r '.streamed' <<<"$result")" != true ]]; then
        jq -r '.content // empty' <<<"$msg"
      fi
      return 0
    fi
  done
}

# ---------------------------------------------------------------- REPL

# ---- prompt ---------------------------------------------------------------
# One line, ASCII only. ~ stands for $HOME, and the directory is cut from the
# left when longer than PROMPT_PATH_MAX. The colour codes are wrapped in
# \001 \002 so readline counts them as zero width.
short_path() {
  local p=$1 home=${HOME%/} max=$PROMPT_PATH_MAX
  if [[ -n "$home" && "$p" == "$home"* ]]; then p="~${p#"$home"}"; fi
  (( max >= 4 )) || max=4
  (( ${#p} <= max )) || p="...${p: -$((max - 3))}"
  printf '%s' "$p"
}

# "branch" or "branch*" when anything is uncommitted. A single git call gets
# the branch and the changes together; empty outside a repository.
git_badge() {
  (( PROMPT_GIT )) || return 0
  local out line b="" dirty=""
  out=$(git -C "$PWD" status --porcelain=v2 --branch 2>/dev/null) || return 0
  while IFS= read -r line; do
    case "$line" in
      "# branch.head "*) b=${line#"# branch.head "} ;;
      "#"*|"") ;;
      *) dirty="*"; break ;;
    esac
  done <<<"$out"
  if [[ "$b" == "(detached)" ]]; then b=detached; fi
  printf '%s' "$b$dirty"
}

# History bytes against COMPACT_AT, in kB; the threshold is omitted when
# automatic compaction is off.
context_badge() {
  (( PROMPT_CONTEXT )) || return 0
  local msgs=${MESSAGES:-} n lim
  n=$(( ${#msgs} / 1024 )); lim=$(( COMPACT_AT / 1024 ))
  if (( AUTO_COMPACT && lim > n )); then printf '%sk/%sk' "$n" "$lim"
  else printf '%sk' "$n"; fi
}

build_prompt_text() {
  local r=$'\001\033[0m\002' s b
  local grn=$'\001\033[32m\002' mag=$'\001\033[35m\002'
  local blu=$'\001\033[34m\002' yel=$'\001\033[33m\002'
  local cyn=$'\001\033[36m\002' dim=$'\001\033[2m\002'
  if [[ "$MODE" == plan ]]; then s=$mag"plan$r"; else s=$grn"build$r"; fi
  s+=" $blu$(short_path "$PWD")$r"
  b=$(git_badge)
  if [[ -n "$b" ]]; then s+=" $yel$b$r"; fi
  if (( PROMPT_MODEL )); then s+=" $dim$MODEL$r"; fi
  b=$(context_badge)
  if [[ -n "$b" ]]; then s+=" $dim$b$r"; fi
  if (( AUTO )); then s+=" ${yel}auto$r"; fi
  s+=" $cyn${SESSION_ID:0:8}$r\$"
  printf '\n%s ' "$s"
}

# Readline history across runs, trimmed so the file cannot grow without bound
if [[ -f "$AGENT_HISTFILE" ]] &&
   (( $(wc -l <"$AGENT_HISTFILE" 2>/dev/null || echo 0) \
        > AGENT_HISTORY_MAX )); then
  if ! { tail -n "$AGENT_HISTORY_MAX" "$AGENT_HISTFILE" \
           >"$AGENT_HISTFILE.$$.tmp" &&
         mv -f "$AGENT_HISTFILE.$$.tmp" "$AGENT_HISTFILE"; } 2>/dev/null; then
    rm -f "$AGENT_HISTFILE.$$.tmp"
  fi
fi
[[ -f "$AGENT_HISTFILE" ]] && chmod 600 "$AGENT_HISTFILE" 2>/dev/null || true
history -r "$AGENT_HISTFILE" 2>/dev/null || true

plugin_hooks start
input="$FIRST_PROMPT"
while true; do
  if [[ -z "$input" ]]; then
    rc=0
    # Read in a subshell with default SIGINT: Ctrl-C kills only the subshell and
    # we draw a fresh prompt (readline under a trap keeps the old, cleared
    # line).
    # The fork inherits the history list, so Up arrow still works.
    # \001 \002 mark the color codes as zero-width for readline
    prompt_text=$(build_prompt_text)
    input=$(trap - INT
            IFS= read -erp "$prompt_text" line &&
            printf '%s' "$line") || rc=$?
    if (( rc > 128 )); then input=""; continue; fi         # Ctrl-C: new prompt
    (( rc == 0 )) || { echo; break; }                       # Ctrl-D: quit
    [[ -z "${input//[[:space:]]/}" ]] && { input=""; continue; }
    history -s -- "$input"
    printf '%s\n' "$input" >>"$AGENT_HISTFILE" 2>/dev/null || true
  fi

  case "$input" in
    /exit|/quit) break ;;
    /sessions)       list_sessions;     echo "Resume one with: /resume <id>" ;;
    "/sessions all") list_sessions all; echo "Resume one with: /resume <id>" ;;
    /resume|"/resume "*)
            read -r arg _ <<<"${input#/resume}" || true
            if [[ -z "$arg" ]]; then
              list_sessions; echo "Usage: /resume <id or unique prefix>"
            else
              # The saved system message may be from the other mode or
              # another directory: bring it in step, as startup does
              if load_session "$arg"; then apply_mode "$MODE"; fi
            fi ;;
    /about) about ;;
    /provider|"/provider info") provider_info ;;
    "/provider list") provider_list ;;
    "/provider use"|"/provider use "*)
            read -r arg rest extra <<<"${input#/provider use}" || true
            if [[ -n "${extra:-}" ]]; then
              echo "Usage: /provider use <name> [model]"
            else
              provider_use "${arg:-}" "${rest:-}"
            fi ;;
    "/provider "*) echo "Usage: /provider [info|list] |"\
                        "/provider use <name> [model]" ;;
    /login|"/login copilot"|"/login github-copilot")
            if copilot_login; then provider_use copilot; fi ;;
    "/login "*) echo "Usage: /login copilot" ;;
    /model|"/model info") model_info ;;
    "/model list") model_list ;;
    "/model use"|"/model use "*)
            read -r arg rest _ <<<"${input#/model use}" || true
            if [[ -n "$rest" ]]; then
              echo "Usage: /model use <number or name>"
            else
              model_use "${arg:-}"
            fi ;;
    /context|"/context info") context_info ;;
    "/context compact"|"/context compact "*)
            read -r val rest _ <<<"${input#/context compact}" || true
            set_model compact_at "${val:-}" "${rest:-}" ;;
    "/context "*)
            read -r val rest _ <<<"${input#/context}" || true
            set_model context "${val:-}" "${rest:-}" ;;
    "/model set"|"/model set "*)
            read -r key val rest _ <<<"${input#/model set}" || true
            set_model "${key:-}" "${val:-}" "${rest:-}" ;;
    "/model "*) echo "Usage: /model [info|list] | /model use <number or"\
                      "name> | /model set <key> <value>" ;;
    /compact) compact || true ;;
    /reset) SESSION_ID=$(new_id); new_history
            echo "New session $SESSION_ID." ;;
    /auto)  if [[ "$AUTO" == 1 ]]; then
              AUTO=0; echo "Commands need confirmation."
            else
              AUTO=1; echo "Commands run WITHOUT confirmation."
            fi ;;
    /plan)  if [[ "$MODE" == plan ]]; then
              echo "Already in plan mode."
            else
              apply_mode plan
              echo "Plan mode: inspect only, no edits (/build to leave)."
            fi ;;
    /build) if [[ "$MODE" == build ]]; then
              echo "Already in build mode."
            else
              apply_mode build
              echo "Build mode: commands run and files can change."
            fi ;;
    /help)  echo "/about           version, author, model and session details"
            echo "/provider list   the providers you can use (current one"\
                 "marked)"
            echo "/provider use N  switch provider (and optionally its"\
                 "model): /provider use copilot gpt-4.1"
            echo "/login copilot   sign in to GitHub Copilot"
            echo "/model list      list the endpoint's models (current one"\
                 "marked)"
            echo "/model use ID    switch by number or name for this run"
            echo "/model           model settings: name, reasoning,"\
                 "thinking, temperature"
            echo "                 (/model set temperature 0.1, /model"\
                 " set reasoning medium)"
            echo "/context         show the context window; /context 128000"\
                 "sets it in tokens,"
            echo "                 /context compact 200000 sets the byte"\
                 "limit (default resets)"
            echo "/compact         summarize the conversation to free up"\
                 "context"
            echo "                 (automatic above $COMPACT_AT bytes;"\
                 "AUTO_COMPACT=0 disables)"
            echo "/sessions [all]  list saved sessions (this directory, or"\
                 "all)"
            echo "/resume ID       switch to a saved session (id or unique"\
                 "prefix)"
            echo "/reset           start a new session (the old one stays"\
                 "resumable)"
            echo "/auto            toggle running commands without"\
                 "confirmation (now: $AUTO)"
            echo "/plan            plan only: read-only commands, no edits"
            echo "/build           leave plan mode and allow edits again"
            echo "/todo [clear]    the model's todo list for this session"
            echo "/plugins         loaded plugins and what they added"
            echo "/exit            quit (or Ctrl-D)"
            if [[ -n "$PLUGIN_COMMAND_HELP" ]]; then
              echo
              echo "Plugin commands:"
              while IFS=$'\x1f' read -r n1 h1 _; do
                [[ -n "$n1" ]] && printf '/%-15s %s\n' "$n1" "$h1"
              done <<<"$PLUGIN_COMMAND_HELP"
            fi
            cmds=$(list_commands)
            if [[ -n "$cmds" ]]; then
              echo
              echo "Prompt commands (text after the name is passed along):"
              printf '%s\n' "$cmds"
            fi ;;
    /plugins) plugin_info ;;
    /todo)  todo_show ;;
    "/todo clear") TODOS='[]'; save_session; echo "Todo list cleared." ;;
    "/todo "*) echo "Usage: /todo [clear]" ;;
    *) # /name [text] runs a prompt command; "/usr/bin is broken" is a message
       if plugin_command_match "$input"; then
         AGENT_PROMPT=""
         if declare -F "cmd_$PLUGIN_CMD" >/dev/null; then
           plugin_call "cmd_$PLUGIN_CMD" "$PLUGIN_ARGS" || true
         else
           printf 'agent.sh: /%s: the plugin did not define cmd_%s\n' \
             "$PLUGIN_CMD" "$PLUGIN_CMD" >&2
         fi
         input="$AGENT_PROMPT"; AGENT_PROMPT=""
       elif [[ "$input" =~ ^/([A-Za-z][A-Za-z0-9_-]*)([[:space:]]+(.*))?$ ]]
       then
         if find_command "${BASH_REMATCH[1]}"; then
           printf '\033[2m(/%s: %s)\033[0m\n' "${BASH_REMATCH[1]}" \
             "$CMD_FILE" >&2
           input=$(render_command "$CMD_FILE" "${BASH_REMATCH[3]:-}")
         else
           echo "Unknown command /${BASH_REMATCH[1]} (try /help)." >&2
           TURN_OK=0
           input=""
         fi
       fi
       if [[ -n "$input" ]]; then
         plugin_hooks turn_start "$input"
         auto_compact        # must run before the new message joins the history
         append "$(printf '%s' "$input" |
                   jq -cRs '{role: "user", content: .}')"
         run_turn
         plugin_hooks turn_end "$TURN_OK"
       fi ;;
  esac
  sync_settings
  input=""
  if (( ONESHOT )); then break; fi
done

plugin_hooks exit
(( ! SUB )) && [[ -f "$(session_file)" ]] &&
  echo "Session saved. Resume with: agent.sh -c  (or -r $SESSION_ID)" >&2
# One-shot runs are used from scripts: a failed turn is a failed run
if (( ONESHOT )) && (( ! TURN_OK )); then exit 1; fi
exit 0
