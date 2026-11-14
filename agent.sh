#!/usr/bin/env bash
# vim: set ts=2 sw=2 sts=2 et ai tw=80 cc=80 ft=sh :
# agent.sh — tiny coding agent for OpenCode Go (OpenAI-compatible API)
#
# Usage: agent.sh [-y] [-p | -b] [-i] [-c | -r SESSION_ID] [-h] [-V] [prompt...]
#        agent.sh -l [all]
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
# environment variables.
# There are two modes. Build (the default) edits files and runs commands.
# Plan only inspects: it runs read-only commands and refuses everything else.
# A long history is summarized by itself once it reaches COMPACT_AT bytes
# (AUTO_COMPACT=0 turns that off), also in the middle of a long turn;
# /compact does it on demand. The latest exchange is kept as it is when it
# is small enough, and everything before it becomes the summary.
# Settings can come from $XDG_CONFIG_HOME/agent.sh/config.json: "provider",
# "model", "url" and "api_key" (plus reasoning, thinking and temperature).
# Environment variables win over that file.
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
# or blank file keeps the built-in, and {{cwd}} is the working directory.
# On the first run the config directory is created and the bundled prompts are
# copied into it as NAME.md.example; rename one to NAME.md to override that
# prompt. A fresh session also prints /about.
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
URL_ENV_SET=${URL+1};                  URL_ENV="${URL-}"
REASONING_ENV_SET=${REASONING+1};      REASONING_ENV="${REASONING-}"
THINKING_ENV_SET=${THINKING+1};        THINKING_ENV="${THINKING-}"
TEMPERATURE_ENV_SET=${TEMPERATURE+1};  TEMPERATURE_ENV="${TEMPERATURE-}"
AGENT_API_KEY_ENV_SET=${AGENT_API_KEY+1}
AGENT_API_KEY_ENV="${AGENT_API_KEY-}"
OPENCODE_API_KEY_ENV_SET=${OPENCODE_API_KEY+1}
OPENCODE_API_KEY_ENV="${OPENCODE_API_KEY-}"
# The key stays in this shell only: commands the model runs must not inherit
# it (an "env" would put it in the transcript and send it to the provider).
unset AGENT_API_KEY OPENCODE_API_KEY
# Sessions, history and temp files hold command output and may hold secrets:
# create them private. Commands the model runs get the original umask back.
ORIG_UMASK=$(umask)
umask 077

MODEL="deepseek-v4.1-flash"            # can come from config or environment
PROVIDER="opencode"                    # opencode (aka opencode-go)
URL=""                                 # default is the provider's endpoint
REASONING="low"                        # reasoning effort ("" = omit the field)
THINKING=""                            # on/off ("" = server default)
TEMPERATURE=""                         # 0..2 ("" = server default)
AUTO="${AUTO:-0}"                      # 1 = no confirmation prompt
MODE="${MODE:-build}"                  # build (edits) or plan (read-only)
MAX_OUT="${MAX_OUT:-20000}"            # tool output bytes sent to the model
AUTO_COMPACT="${AUTO_COMPACT:-1}"      # 1 = auto-summarize a long history
COMPACT_AT="${COMPACT_AT:-100000}"     # history bytes that trigger that
TIMEOUT="${TIMEOUT:-300}"              # seconds of silence before giving up
OUTSIDE="${OUTSIDE:-ask}"              # outside the workspace: ask, allow, deny
# Programs that always need approval, also under -y ("" = none)
ASK_CMDS="${ASK_CMDS-sudo su doas pkexec dd mkfs fdisk parted shutdown reboot \
poweroff halt systemctl nixos-rebuild crontab chown mount umount}"
WORKSPACE="${WORKSPACE:-}"             # default: the git repository, else $PWD
ALLOW_PATHS="${ALLOW_PATHS:-}"         # extra directories, colon-separated
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
API_KEY=""                             # set by load_settings
API_KEY_SOURCE=""
CONFIG_LOADED=0

VERSION="0.3.0"
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

# The endpoint for a known provider; fails for one we do not know.
provider_url() {
  case "$1" in
    opencode|opencode-go)
      printf '%s' 'https://opencode.ai/zen/go/v1/chat/completions' ;;
    *) return 1 ;;
  esac
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
  v=$(config_get "$f" model)
  if [[ -n "$v" ]]; then MODEL="$v"; fi
  v=$(config_get "$f" url)
  if [[ -n "$v" ]]; then URL="$v"; fi
  v=$(config_get "$f" api_key)
  if [[ -n "$v" ]]; then API_KEY="$v"; API_KEY_SOURCE="config"; fi
  v=$(config_get "$f" reasoning)
  if [[ -n "$v" ]]; then
    case "$v" in
      default|off|none) REASONING="" ;;
      *) REASONING="$v" ;;
    esac
  fi
  v=$(config_get "$f" thinking)
  if [[ -n "$v" ]]; then
    case "$v" in
      default|auto) THINKING="" ;;
      *) THINKING="$v" ;;
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

  if [[ -n "$PROVIDER_ENV_SET" ]]; then PROVIDER="$PROVIDER_ENV"; fi
  if [[ -n "$URL_ENV_SET" ]]; then URL="$URL_ENV"; fi
  if [[ -n "$MODEL_ENV_SET" ]]; then MODEL="$MODEL_ENV"; fi
  if [[ -n "$REASONING_ENV_SET" ]]; then REASONING="$REASONING_ENV"; fi
  if [[ -n "$THINKING_ENV_SET" ]]; then THINKING="$THINKING_ENV"; fi
  if [[ -n "$TEMPERATURE_ENV_SET" ]]; then
    TEMPERATURE="$TEMPERATURE_ENV"
  fi
  if [[ -n "$OPENCODE_API_KEY_ENV_SET" ]]; then
    API_KEY="$OPENCODE_API_KEY_ENV"
    API_KEY_SOURCE="env OPENCODE_API_KEY"
  fi
  if [[ -n "$AGENT_API_KEY_ENV_SET" ]]; then
    API_KEY="$AGENT_API_KEY_ENV"
    API_KEY_SOURCE="env AGENT_API_KEY"
  fi
  if [[ -z "$MODEL" ]]; then
    printf 'agent.sh: model must not be empty\n' >&2
    exit 2
  fi
  if [[ -z "$API_KEY" ]]; then
    printf '%s %s\n' \
      'agent.sh: no API key: set AGENT_API_KEY or OPENCODE_API_KEY,' \
      "or \"api_key\" in $CONFIG_FILE" >&2
    exit 2
  fi
  if [[ -z "$URL" ]]; then
    if ! URL=$(provider_url "$PROVIDER"); then
      printf 'agent.sh: unknown provider "%s"; set "url" in %s\n' \
        "$PROVIDER" "$CONFIG_FILE" >&2
      exit 2
    fi
  fi
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

# The text of the first non-blank <prompt dir>/$1, else $2. {{cwd}} in it
# stands for the working directory (the file cannot expand it).
read_prompt() {
  local name="$1" fallback="$2" dir f t="" ph='{{cwd}}' i=0
  PROMPT_FROM="built-in"
  for dir in "${PROMPT_DIRS[@]}"; do
    f="$dir/$name"
    [[ -f "$f" ]] || continue
    t=$(cat "$f" 2>/dev/null) || t=""
    t=${t#"${t%%[![:space:]]*}"}          # trim, a blank file falls back too
    t=${t%"${t##*[![:space:]]}"}
    if [[ -n "$t" ]]; then PROMPT_FROM="$f"; break; fi
  done
  while [[ "$t" == *"$ph"* ]] && (( i++ < 100 )); do
    t="${t%%"$ph"*}${PWD}${t#*"$ph"}"
  done
  printf '%s' "${t:-$fallback}"
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

usage() { sed -n '4,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0"; }

# The current model settings (REPL: /model or /model info)
model_info() {
  printf '  %-11s %s\n' model "$MODEL"
  printf '  %-11s %s\n' reasoning "${REASONING:-server default}"
  printf '  %-11s %s\n' thinking "${THINKING:-server default}"
  printf '  %-11s %s\n' temperature "${TEMPERATURE:-server default}"
  printf '  %-11s %s\n' endpoint "$URL"
  printf 'Change one with: /model set <model|reasoning|thinking|'\
'temperature> <value>\n'
}

# /model set <key> <value>: validates and stores one setting for this run
set_model() {
  local key="${1:-}" val="${2:-}" rest="${3:-}"
  case "$key" in
    temp)   key=temperature ;;
    effort) key=reasoning ;;
  esac
  case "$key" in
    model|reasoning|thinking|temperature) ;;
    "") echo "Usage: /model set <model|reasoning|thinking|temperature>"\
             "<value>"; return 0 ;;
    *)  echo "Unknown setting '$key' (model, reasoning, thinking or"\
             "temperature)."; return 0 ;;
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
  esac
  case "$key" in
    model)       printf 'model = %s\n' "$MODEL" ;;
    reasoning)   printf 'reasoning = %s\n' "${REASONING:-server default}" ;;
    thinking)    printf 'thinking = %s\n' "${THINKING:-server default}" ;;
    temperature) printf 'temperature = %s\n' "${TEMPERATURE:-server default}" ;;
  esac
}

# Version and environment details (REPL: /about, CLI: -V or --version)
about() {
  local jq_ver curl_ver run cfg_note=""
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
  printf '  %-9s %s\n' sessions "$SESSION_DIR"
  printf '  %-9s %s\n' auto "$run"
  if [[ "$MODE" == plan ]]; then
    printf '  %-9s %s\n' mode 'plan (read-only commands, no edits)'
  else
    printf '  %-9s %s\n' mode 'build (edits and commands allowed)'
  fi
  if (( AUTO_COMPACT )); then
    printf '  %-9s automatic above %s bytes\n' compact "$COMPACT_AT"
  else
    printf '  %-9s only with /compact\n' compact
  fi
  printf '  %-9s %s\n' prompts "$(prompt_notes)"
  printf '  %-9s %s\n' project "${PROJECT_DOC_USED:-no AGENTS.md here}"
  printf '  %-9s %s (outside it: %s)\n' workspace "${WORKSPACE:-$PWD}" \
    "$OUTSIDE"
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
# getopts cannot see long options: take them out of the leading options first
# and stop at the first prompt word, so "--plan" inside a prompt is just text.
ARGS=()
while (( $# )); do
  case "$1" in
    --help)    usage; exit 0 ;;
    --version) printf 'agent.sh %s\n' "$VERSION"; exit 0 ;;
    --plan)    ARGS+=(-p); shift ;;       # in order, so the last one wins
    --build)   ARGS+=(-b); shift ;;
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
  MODE=plan; AUTO=1; SUBAGENTS=0; MAX_STEPS="$SUB_MAX_STEPS"
  [[ -n "$FIRST_PROMPT" ]] ||
    { echo "agent.sh: an explorer needs a task" >&2; exit 2; }
  ONESHOT=1
else
  SUB=0
fi
for dep in SUB_MAX SUB_TIMEOUT SUB_MAX_STEPS MAX_STEPS; do
  [[ "${!dep}" =~ ^[0-9]+$ ]] ||
    { echo "agent.sh: $dep must be a whole number" >&2; exit 2; }
done
[[ "$SUBAGENTS" == 0 || "$SUBAGENTS" == 1 ]] ||
  { echo "agent.sh: SUBAGENTS must be 0 or 1" >&2; exit 2; }
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
load_settings
warn_config_permissions

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

# OpenAI-style tool definitions
# Built with jq: a JSON string cannot be broken across lines
TOOLS=$(jq -cn --argjson sub "$SUBAGENTS" '
  [{type: "function", function: {
    name: "bash",
    description: ("Run a bash script in the current directory. Returns " +
                  "combined stdout/stderr and the exit code if non-zero."),
    parameters: {type: "object",
      properties: {command: {type: "string",
        description: "The bash command or script to run"}},
      required: ["command"]}}}]
  + (if $sub == 1 then
  [{type: "function", function: {
    name: "explore",
    description: ("Start a read-only sub-agent that explores the project " +
                  "and returns a report. It can only run read-only commands " +
                  "and does not see this conversation, so give it a " +
                  "self-contained task: what to find out, where to look, " +
                  "and what to report. Several explore calls in one reply " +
                  "run in parallel: split a broad search into independent " +
                  "tasks. Use bash yourself for a quick single lookup."),
    parameters: {type: "object",
      properties: {task: {type: "string",
        description: "What the explorer should find out and report"}},
      required: ["task"]}}}]
  else [] end)')

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
  [[ -s "$TMP/auth" ]] ||
    printf 'Authorization: Bearer %s\n' "$API_KEY" >"$TMP/auth" 2>/dev/null ||
    true
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
[[ "$CMD_TIMEOUT" =~ ^[0-9]+$ ]] ||
  { echo "agent.sh: CMD_TIMEOUT must be a whole number of seconds" >&2; exit 2; }
# Ctrl-C kills the foreground child (curl / the command) but not the agent
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

# ---------------------------------------------------------------- sessions

session_file() { printf '%s/%s.json' "$SESSION_DIR" "$SESSION_ID"; }

save_session() {
  local f; f=$(session_file)
  [[ -d "$SESSION_DIR" ]] || mkdir -p "$SESSION_DIR" 2>/dev/null || true
  if ! jq -c --arg id "$SESSION_ID" --arg cwd "$PWD" \
         '{id: $id, cwd: $cwd, messages: .}' \
         <<<"$MESSAGES" >"$f.$$.tmp" 2>/dev/null ||
     ! mv -f "$f.$$.tmp" "$f"; then
    echo "warning: could not save session to $f" >&2
  fi
}

new_history() {
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

# Switches to a saved session; the current one is already saved
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
  n=$(jq '[.[] | select(.role == "user")] | length' <<<"$MESSAGES")
  echo "Resumed session $SESSION_ID ($n user messages)" >&2
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
  load_session "$RESUME" || exit 1
else
  SESSION_ID="${SESSION_ID:-$(new_id)}"
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
http_post() {
  curl -sSN --connect-timeout 30 --speed-limit 1 --speed-time "$TIMEOUT" \
    -D "$TMP/hdr" "$URL" \
    -H @"$TMP/auth" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -H "x-opencode-session: $SESSION_ID" \
    -d @-
}

# Sends $1 (a messages array), leaves the raw stream in $TMP/sse. $2 is a list
# of flags: "quiet" keeps the reply off the screen, otherwise it is streamed as
# it arrives; "notools" sends no tool definitions, so the reply is text. Retries only when nothing arrived or the server asks to retry, never
# after part of a reply was already shown.
request() {
  local msgs="$1" flags=" ${2:-} " attempt code body notools=0
  ensure_tmp
  if [[ "$flags" == *" notools "* ]]; then notools=1; fi
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
  for attempt in 1 2 3 4; do
    : >"$TMP/sse"; : >"$TMP/hdr"
    if [[ "$flags" == *" quiet "* ]]; then
      printf '%s' "$body" | http_post | tee "$TMP/sse" >/dev/null || true
    else
      printf '%s' "$body" | http_post | tee "$TMP/sse" | show_stream || true
    fi
    (( INTERRUPTED )) && return 0
    code=$(awk '/^HTTP\//{c = $2} END{print c}' "$TMP/hdr")
    [[ -s "$TMP/sse" && ! "$code" =~ ^(408|429|5[0-9][0-9])$ ]] && return 0
    (( attempt < 4 )) || return 0
    printf '(request failed%s; retrying in %ss...)\n' \
      "${code:+, HTTP $code}" $((attempt * 2)) >&2
    sleep $((attempt * 2)) || true
    (( INTERRUPTED )) && return 0
  done
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
           sha512sum cksum test true false '[' '[[' ']]' : cd)
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
  # others write a file or start a program
  for a; do
    case "$a" in
      -c|--config-env*|--output*|-O*|--open-files-in-pager*|--ext-diff)
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
    status|diff|log|show|blame|ls-files|ls-tree|ls-remote|rev-parse|grep|\
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
          for a; do
            case "$a" in --o*|-[!-]*o*|-o*) return 1 ;; esac
          done ;;
    date) for a; do
            case "$a" in -s*|--s*) return 1 ;; esac
          done ;;
    rg)   for a; do
            case "$a" in --pre*) return 1 ;; esac
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
# line. It reads the text of the
# command: absolute paths, ~, $HOME and paths that climb with "..". It cannot
# see what a script or program does on its own, a path built from other
# variables, or where a symbolic link leads.
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
    case "$p/" in "$WORKSPACE"/*|"$START_DIR"/*) continue ;; esac
    if [[ "$WORKSPACE" == / ]]; then continue; fi
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
# Ctrl-C and the timeout end the whole group, background jobs included. (no subshell, so Ctrl-C state
# survives)
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
  local got_term=0 gone="" outside="" approved="" risky="" why
  local -a run=()
  if (( SUB )); then
    # One dim line per command; the parent's terminal is shared with others
    printf '\033[2m[%s] $ %s\033[0m\n' "$SUB_NAME" "${cmd%%$'\n'*}" >&2
  else
    printf '\n\033[33m$ %s\033[0m\n' "$cmd" >&2
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
  if [[ -n "$outside" || -n "$risky" ]]; then
    why=""
    if [[ -n "$outside" ]]; then
      why="it reaches outside the workspace ($WORKSPACE): $outside"
    fi
    if [[ -n "$risky" ]]; then why+="${why:+; }it is dangerous: $risky"; fi
    TOOL_OUT="Not run: $why."
    if [[ -n "$outside" && "$OUTSIDE" == deny ]]; then
      TOOL_OUT+=" Leaving the workspace is not allowed in this session; work"
      TOOL_OUT+=" inside it."
      printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
      return
    fi
    if ! { true </dev/tty; } 2>/dev/null; then
      TOOL_OUT+=" It needs the user's approval and there is no terminal to"
      TOOL_OUT+=" ask on. Find another way, or tell the user what you need"
      TOOL_OUT+=" and why."
      printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&9
      return
    fi
    printf '\033[35mNeeds your approval: %s\033[0m\n' "$why" >&2
    read -rp "Allow it? [y/N/a=always this session, or say why not] " ok \
      </dev/tty || ok=""
    case "$ok" in
      [Yy]|[Yy][Ee][Ss]) approved=1 ;;
      [Aa]|[Aa]lways)
        approved=1
        if [[ -n "$outside" ]]; then
          OUTSIDE=allow
          echo "Commands may now leave the workspace without asking." >&2
        fi
        if [[ -n "$risky" ]]; then
          RISK_OK=1
          echo "Dangerous commands now run without this question." >&2
        fi ;;
      ""|[Nn]|[Nn][Oo])
        TOOL_OUT+=" The user did not allow it."
        printf '%s\n' "$TOOL_OUT" >&2
        return ;;
      *)
        TOOL_OUT+=" The user did not allow it and said: $ok"
        printf '%s\n' "$TOOL_OUT" >&2
        return ;;
    esac
  fi
  if [[ "$AUTO" != 1 && -z "$approved" ]]; then
    if ! { true </dev/tty; } 2>/dev/null; then   # nothing to ask the user on
      TOOL_OUT="The user declined to run this command (no terminal to ask"
      TOOL_OUT+=" on; run with -y to approve commands up front)."
      printf '%s\n' "$TOOL_OUT" >&2
      return
    fi
    read -rp "Run it? [y/N/a=always, or say why not] " ok </dev/tty || ok=""
    case "$ok" in
      [Yy]|[Yy][Ee][Ss]) ;;
      [Aa]|[Aa]lways)
        AUTO=1
        echo "Commands now run without asking (/auto to undo)." >&2 ;;
      ""|[Nn]|[Nn][Oo])
        TOOL_OUT="The user declined to run this command."
        printf '%s\n' "$TOOL_OUT" >&2
        return ;;
      *)  # anything else is the reason, passed on so the model can adjust
        TOOL_OUT="The user declined to run this command and said: $ok"
        printf '%s\n' "$TOOL_OUT" >&2
        return ;;
    esac
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
  line=${task%%$'\n'*}
  if (( ${#line} > 100 )); then line="${line:0:100}..."; fi
  printf '\033[33m[explorer %s] %s\033[0m\n' "$n" "$line" >&2
  (
    umask "$ORIG_UMASK"
    # The key and the settings of this run go by environment, not argv
    export AGENT_SUB=1 AGENT_SUB_NAME="explorer $n" AGENT_API_KEY="$API_KEY"
    export MODEL PROVIDER URL REASONING THINKING TEMPERATURE MAX_OUT TIMEOUT
    export CMD_TIMEOUT SUB_MAX_STEPS PROJECT_DOC AUTO_COMPACT COMPACT_AT
    export OUTSIDE WORKSPACE ALLOW_PATHS ASK_CMDS
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
TOOL_NAMES=$(jq -r '[.[].function.name] | join(", ")' <<<"$TOOLS")

# One user turn: call the model, run its tools, repeat until it stops.
# TURN_OK is 0 afterwards if the turn failed or was interrupted.
TURN_OK=1
run_turn() {
  local result msg call id name cmd out n ncalls steps=0
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
      jq -r '(.error // "(no response)")
             | if type == "object" then (.message // tojson) else . end
             | if . == "" then "(no response)" else . end' <<<"$result" >&2
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
      elif [[ "$name" != "bash" ]]; then
        out="Error: unknown tool '$name'. The tools are: $TOOL_NAMES."
        printf '%s\n' "$out" >&2
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

# Readline history across runs, trimmed so the file cannot grow without bound
if [[ -f "$AGENT_HISTFILE" ]] &&
   (( $(wc -l <"$AGENT_HISTFILE" 2>/dev/null || echo 0) \
        > AGENT_HISTORY_MAX )); then
  tail -n "$AGENT_HISTORY_MAX" "$AGENT_HISTFILE" >"$AGENT_HISTFILE.$$.tmp" &&
    mv -f "$AGENT_HISTFILE.$$.tmp" "$AGENT_HISTFILE" ||
    rm -f "$AGENT_HISTFILE.$$.tmp"
fi
[[ -f "$AGENT_HISTFILE" ]] && chmod 600 "$AGENT_HISTFILE" 2>/dev/null || true
history -r "$AGENT_HISTFILE" 2>/dev/null || true

input="$FIRST_PROMPT"
while true; do
  if [[ -z "$input" ]]; then
    rc=0
    # Read in a subshell with default SIGINT: Ctrl-C kills only the subshell and
    # we draw a fresh prompt (readline under a trap keeps the old, cleared
    # line).
    # The fork inherits the history list, so Up arrow still works.
    # \001 \002 mark the color codes as zero-width for readline
    if [[ "$MODE" == plan ]]; then
      prompt_text=$'\n\001\033[35m\002plan\001\033[0m\002 '
    else
      prompt_text=$'\n'
    fi
    prompt_text+=$'\001\033[36m\002'"$SESSION_ID"$'$\001\033[0m\002 '
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
    /model|"/model info") model_info ;;
    "/model set"|"/model set "*)
            read -r key val rest _ <<<"${input#/model set}" || true
            set_model "${key:-}" "${val:-}" "${rest:-}" ;;
    "/model "*) echo "Usage: /model [info] | /model set <key> <value>" ;;
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
            echo "/model           model settings: name, reasoning,"\
                 "thinking, temperature"
            echo "                 (/model set temperature 0.1, /model"\
                 " set reasoning medium)"
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
            echo "/exit            quit (or Ctrl-D)" ;;
    *) auto_compact          # must run before the new message joins the history
       append "$(printf '%s' "$input" | jq -cRs '{role: "user", content: .}')"
       run_turn ;;
  esac
  input=""
  if (( ONESHOT )); then break; fi
done

(( ! SUB )) && [[ -f "$(session_file)" ]] &&
  echo "Session saved. Resume with: agent.sh -c  (or -r $SESSION_ID)" >&2
# One-shot runs are used from scripts: a failed turn is a failed run
if (( ONESHOT )) && (( ! TURN_OK )); then exit 1; fi
exit 0
