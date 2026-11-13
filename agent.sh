#!/usr/bin/env bash
# vim: set ts=2 sw=2 sts=2 et ai tw=80 cc=80 ft=sh :
# agent.sh — tiny coding agent for OpenCode Go (OpenAI-compatible API)
#
# Usage: agent.sh [-y] [-p] [-c | -r SESSION_ID] [-h] [-V] [prompt...]
#        agent.sh -l [all]
#   -y       run commands without asking (same as AUTO=1)
#   -p       start in plan mode: read-only commands, no edits (/build)
#   -c       continue the most recent session in this directory
#   -r ID    resume a specific session (full id or a unique prefix)
#   -l       list saved sessions for this directory ("all": every directory)
#   -h       show this help (--help works too)
#   -V       show the version (--version works too)
#   prompt   optional first message (put -- before one that starts with '-')
#
# REPL commands: /help  /about  /compact  /sessions [all]  /resume ID
#                /reset  /auto  /plan  /build  /exit (or Ctrl-D)
# There are two modes. Build (the default) edits files and runs commands.
# Plan only inspects: it runs read-only commands and refuses everything else.
# A long history is summarized by itself once it reaches COMPACT_AT bytes
# (AUTO_COMPACT=0 turns that off); /compact does it on demand.
# The built-in prompts can be replaced by SYSTEM.md, COMPACTION.md and PLAN.md
# in ./pro.mpts/ (or $PROMPT_DIR); a missing or empty file keeps the built-in,
# and {{cwd}} in a file is replaced by the working directory.
# Ctrl-C stops the current reply or command without ending the session.
# Sessions are saved as JSON in $SESSION_DIR (~/.local/state/agent.sh/sessions).
set -euo pipefail

MODEL="${MODEL:-deepseek-v4.1-flash}"
URL="${URL:-https://opencode.ai/zen/go/v1/chat/completions}"
AUTO="${AUTO:-0}"                          # 1 = no confirmation prompt
MODE="${MODE:-build}"                      # build (edits) or plan (read-only)
MAX_OUT="${MAX_OUT:-20000}"                # tool output bytes sent to the model
AUTO_COMPACT="${AUTO_COMPACT:-1}"          # 1 = auto-summarize a long history
COMPACT_AT="${COMPACT_AT:-100000}"         # history bytes that trigger that
TIMEOUT="${TIMEOUT:-300}"                  # seconds of silence before giving up
SHOW_REASONING="${SHOW_REASONING:-1}"      # 1 = stream reasoning (dimmed)
AGENT_HISTFILE="${AGENT_HISTFILE:-$HOME/.agent_sh_history}"
AGENT_HISTORY_MAX="${AGENT_HISTORY_MAX:-1000}"   # lines kept in that file
SESSION_DIR="${SESSION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}\
/agent.sh/sessions}"
PROMPT_DIR="${PROMPT_DIR:-./pro.mpts}"     # optional prompt overrides

VERSION="0.1.0"
RELEASED="2026-11-13"
AUTHOR="fb87"                                       # see LICENSE

new_id() {
  uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null ||
    echo "bash-agent-$$-$(date +%s)"
}

# The text of $PROMPT_DIR/$1 when that file exists and is not blank, else $2.
# {{cwd}} in it stands for the working directory (the file cannot expand it).
read_prompt() {
  local f="$PROMPT_DIR/$1" t="" ph='{{cwd}}' i=0
  [[ -f "$f" ]] && t=$(cat "$f" 2>/dev/null)
  t=${t#"${t%%[![:space:]]*}"}            # trim, so a blank file falls back too
  t=${t%"${t##*[![:space:]]}"}
  while [[ "$t" == *"$ph"* ]] && (( i++ < 100 )); do
    t="${t%%"$ph"*}${PWD}${t#*"$ph"}"
  done
  printf '%s' "${t:-$2}"
}

# Which prompts are in use, for /about
prompt_notes() {
  local f n=""
  for f in SYSTEM.md COMPACTION.md PLAN.md; do
    [[ -n "$(read_prompt "$f" '')" ]] && n+="${n:+, }$f"
  done
  if [[ -n "$n" ]]; then printf '%s from %s' "$n" "$PROMPT_DIR"
  else printf 'built-in'; fi
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

# Version and environment details (REPL: /about, CLI: -V or --version)
about() {
  local jq_ver curl_ver run
  jq_ver=$(jq --version 2>/dev/null); jq_ver=${jq_ver/jq-/jq }
  curl_ver=$(curl --version 2>/dev/null | head -1 | cut -d' ' -f1,2)
  if [[ "$AUTO" == 1 ]]; then run="run without asking"; else run="ask first"; fi
  printf 'agent.sh %s — a coding agent in bash\n' "$VERSION"
  printf '  %-9s %s\n' author "$AUTHOR"
  printf '  %-9s %s\n' released "$RELEASED"
  printf '  %-9s MIT (see LICENSE)\n' license
  printf '  %-9s %s\n' model "$MODEL"
  printf '  %-9s %s\n' endpoint "$URL"
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
  printf '  %-9s %s, %s, %s\n' runtime \
    "bash $BASH_VERSION" "$jq_ver" "$curl_ver"
  printf '  %-9s %s\n' script "$0"
}

RESUME=""
LIST=0
for arg in "$@"; do                    # getopts cannot see long options
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --version) printf 'agent.sh %s\n' "$VERSION"; exit 0 ;;
    --plan) MODE=plan ;;
    --build) MODE=build ;;
    --) break ;;
  esac
done
while getopts ":ycr:lhVp" opt; do
  case "$opt" in
    y) AUTO=1 ;;
    p) MODE=plan ;;
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
if (( LIST )); then list_sessions "${1:-}"; exit 0; fi
FIRST_PROMPT="$*"
case "$MODE" in
  build|plan) ;;
  *) echo "agent.sh: MODE must be 'build' or 'plan'" >&2; exit 2 ;;
esac

: "${OPENCODE_API_KEY:?Please export OPENCODE_API_KEY}"
for dep in jq curl; do
  command -v "$dep" >/dev/null ||
    { echo "agent.sh: '$dep' is required" >&2; exit 1; }
done

SYSTEM_DEFAULT="You are a coding agent working in the user's current directory
($PWD). Use the bash tool to inspect, create, edit and run files. Each command
runs in a fresh non-interactive bash process with no stdin, so 'cd' and
variables do not persist between calls and interactive programs will not work.
Be concise."
PLAN_DEFAULT='PLAN MODE: plan only, do not change anything. Inspect the '
PLAN_DEFAULT+='project with read-only commands (ls, cat, head, tail, grep, '
PLAN_DEFAULT+='git status/diff/log/show, ...); other commands are refused '
PLAN_DEFAULT+='by the harness. Do not edit, create or delete files, commit '
PLAN_DEFAULT+='or run builds and tests that touch the tree. Finish with a '
PLAN_DEFAULT+='concrete, step-by-step plan: the files to change, the exact '
PLAN_DEFAULT+='edits, and how to verify them. Say what you would do, not '
PLAN_DEFAULT+='what you did.'
BASE_SYSTEM=$(read_prompt SYSTEM.md "$SYSTEM_DEFAULT")
PLAN_PROMPT=$(read_prompt PLAN.md "$PLAN_DEFAULT")
SYSTEM="$BASE_SYSTEM"

# OpenAI-style tool definition
# Built with jq: a JSON string cannot be broken across lines
TOOLS=$(jq -cn '
  [{type: "function", function: {
    name: "bash",
    description: ("Run a bash script in the current directory. Returns " +
                  "combined stdout/stderr and the exit code if non-zero."),
    parameters: {type: "object",
      properties: {command: {type: "string",
        description: "The bash command or script to run"}},
      required: ["command"]}}}]')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Ctrl-C kills the foreground child (curl / the command) but not the agent
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

# ---------------------------------------------------------------- sessions

session_file() { printf '%s/%s.json' "$SESSION_DIR" "$SESSION_ID"; }

save_session() {
  local f; f=$(session_file)
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
  [[ "$MODE" == plan ]] && SYSTEM+=$'\n\n'"$PLAN_PROMPT"
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
if [[ -n "$RESUME" ]]; then
  if [[ "$RESUME" == last ]]; then
    RESUME=$(find_last_session) ||
      { echo "agent.sh: no saved session for $PWD" >&2; exit 1; }
  fi
  load_session "$RESUME" || exit 1
else
  SESSION_ID="${SESSION_ID:-$(new_id)}"
  new_history
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
    -H "Authorization: Bearer $OPENCODE_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -H "x-opencode-session: $SESSION_ID" \
    -d @-
}

# Sends $1 (a messages array), leaves the raw stream in $TMP/sse. $2 = quiet
# keeps the reply off the screen (compaction), otherwise it is streamed as it
# arrives. Retries only when nothing arrived or the server asks to retry, never
# after part of a reply was already shown.
request() {
  local msgs="$1" quiet="${2:-}" attempt code body
  body=$(jq -c --arg model "$MODEL" --argjson tools "$TOOLS" \
    --arg mode "$quiet" \
    '{model: $model, reasoning_effort: "low", messages: ., stream: true}
     + (if $mode == "quiet" then {} else {tools: $tools} end)' <<<"$msgs")
  for attempt in 1 2 3 4; do
    : >"$TMP/sse"; : >"$TMP/hdr"
    if [[ "$quiet" == quiet ]]; then
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

call_api() { request "$MESSAGES"; }

# ---------------------------------------------------------------- compacting

# What to keep when the conversation is folded into a summary
COMPACT_DEFAULT='Summarize the conversation above so that everything '
COMPACT_DEFAULT+='before it can be dropped from the context. Keep the '
COMPACT_DEFAULT+='task and its goal, the decisions and why, the files and '
COMPACT_DEFAULT+='paths involved, the commands run and what they showed, '
COMPACT_DEFAULT+='the current state, and what is left to do. Output the '
COMPACT_DEFAULT+='summary only, no preamble.'
COMPACT_ASK=$(read_prompt COMPACTION.md "$COMPACT_DEFAULT")

# Folds the conversation into one summary message (system + summary). The old
# transcript is left next to the session file as <id>.json.bak.
compact() {
  local msgs result summary count before after
  INTERRUPTED=0            # a Ctrl-C that ended the previous turn is not ours
  count=$(jq '[.[] | select(.role != "system")] | length' <<<"$MESSAGES")
  if (( count == 0 )); then
    echo "Nothing to compact yet."
    return 1
  fi
  msgs=$(jq -c --arg q "$COMPACT_ASK" "$REPAIR"'
      | . + [{role: "user", content: $q}]' <<<"$MESSAGES")
  request "$msgs" quiet
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
  MESSAGES=$(jq -cn --arg s "$SYSTEM" --arg sum "$summary" '
      [{role: "system", content: $s},
       {role: "user",
        content: ("Summary of the conversation so far (everything before it "
                  + "was compacted to save context):\n\n") + $sum}]')
  save_session
  after=$(printf '%s' "$MESSAGES" | wc -c)
  printf '(compacted %s messages, %s bytes -> one summary, %s bytes)\n' \
    "$count" "$before" "$after"
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
  compact || printf '(compaction failed; carrying on)\n' >&2
  return 0
}

# ---------------------------------------------------------------- tools

# Plan mode may only inspect. This is a guard, not a sandbox: it refuses
# redirections, substitutions and anything whose first word it does not know.
PLAN_CMDS=(ls cat head tail wc grep egrep fgrep rg find file stat pwd echo
           printf cut tr diff comm cmp jq basename dirname readlink realpath
           du df which type uname date id ps seq nl od strings paste join
           expand unexpand fold tac rev sort tree md5sum sha1sum sha256sum
           sha512sum cksum test true false '[' '[[' : cd)

# git is allowed only for subcommands that do not change the repository
plan_git_ok() {
  local -a w; local i=1 sub=""
  # -c / --config-env can define aliases and pagers that run commands
  case " $1 " in
    *" --output"*|*" -c "*|*" --config-env"*) return 1 ;;
    *" -O "*|*" --open-files-in-pager"*) return 1 ;;
  esac
  read -ra w <<<"$1"
  while (( i < ${#w[@]} )); do
    case "${w[i]}" in
      -C|-c) (( i += 2 )) ;;
      -*)    (( i += 1 )) ;;
      *)     sub=${w[i]}; break ;;
    esac
  done
  case "$sub" in
    status|diff|log|show|blame|ls-files|ls-tree|ls-remote|rev-parse|grep|\
    cat-file|show-ref|shortlog|describe|for-each-ref)
      return 0 ;;
    branch) case "${w[i+1]:-}" in
              ""|-a|-r|-v|-vv|--list|--show-current|--contains|--merged)
                return 0 ;;
              *) return 1 ;;
            esac ;;
    tag) case "${w[i+1]:-}" in ""|-l|--list|-n*) return 0 ;;
            *) return 1 ;; esac ;;
    remote) case "${w[i+1]:-}" in ""|-v|--verbose|show|get-url) return 0 ;;
            *) return 1 ;; esac ;;
    config) case "${w[i+1]:-}" in
              -l|--list|--get|--get-all|--get-regexp|--get-urlmatch) return 0 ;;
              *) return 1 ;;
            esac ;;
    stash) case "${w[i+1]:-}" in list|show) return 0 ;; *) return 1 ;; esac ;;
    reflog) case "${w[i+1]:-}" in ""|show) return 0 ;; *) return 1 ;; esac ;;
    worktree|submodule) case "${w[i+1]:-}" in
              list|status|summary) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

plan_allows() {
  local cmd="$1" frag w c open="\$(" ok=""
  case "$cmd" in *'>'*|*'<'*|*'`'*|*"$open"*) return 1 ;; esac
  while IFS= read -r frag; do
    frag=${frag#"${frag%%[![:space:]]*}"}
    [[ -z "$frag" ]] && continue
    w=${frag%%[[:space:]]*}
    case "$w" in
      git) plan_git_ok "$frag" || return 1; continue ;;
      find) case " $frag " in
              *" -delete "*|*" -exec "*|*" -execdir "*|*" -ok "*|*" -fprint"*)
                return 1 ;;
            esac ;;
      sort|tree) case " $frag " in
              *" -o "*|*" --output "*|*--output=*) return 1 ;;
            esac ;;
      date) case " $frag " in *" -s "*|*" --set"*) return 1 ;; esac ;;
      rg) case " $frag " in *" --pre "*|*" --pre="*) return 1 ;; esac ;;
    esac
    ok=""
    for c in "${PLAN_CMDS[@]}"; do
      [[ "$c" == "$w" ]] && { ok=1; break; }
    done
    [[ -n "$ok" ]] || return 1
  done < <(printf '%s\n' "$cmd" | tr ';|&' '\n')
  return 0
}

# Runs one command; result goes in TOOL_OUT (no subshell, so Ctrl-C state
# survives)
run_tool() {
  local cmd="$1" ok="" rc=0 out size half note=""
  printf '\n\033[33m$ %s\033[0m\n' "$cmd" >&2
  if [[ "$MODE" == plan ]] && ! plan_allows "$cmd"; then
    TOOL_OUT="Plan mode: command not run. Only read-only inspection"
    TOOL_OUT+=" commands are allowed here; /build leaves plan mode."
    printf '\033[33m%s\033[0m\n' "$TOOL_OUT" >&2
    return
  fi
  if [[ "$AUTO" != 1 ]]; then
    if ! { true </dev/tty; } 2>/dev/null; then   # nothing to ask the user on
      TOOL_OUT="The user declined to run this command (no terminal to ask"
      TOOL_OUT+=" on; run with -y to approve commands up front)."
      printf '%s\n' "$TOOL_OUT" >&2
      return
    fi
    read -rp "Run it? [y/N] " ok </dev/tty || ok=""
    if [[ ! "$ok" =~ ^[Yy] ]]; then
      TOOL_OUT="The user declined to run this command."
      printf '%s\n' "$TOOL_OUT" >&2
      return
    fi
  fi
  # Run from a file: passing the script via 'bash -c' would hit the argv limit
  printf '%s\n' "$cmd" >"$TMP/cmd.sh"
  # Stream output live to the terminal while saving it to a file, so partial
  # output survives Ctrl-C and huge output never has to fit in a variable
  # ${PIPESTATUS[0]} is the command's own status: under pipefail, $? is tee's
  # when the output was not delivered (e.g. 'agent.sh ... | head'), which used
  # to report a failed command that had in fact succeeded
  if ! bash "$TMP/cmd.sh" </dev/null 2>&1 | tee "$TMP/out" >&2; then
    rc=${PIPESTATUS[0]}
  fi

  size=$(wc -c <"$TMP/out")
  if (( size > MAX_OUT )); then           # keep head and tail, say what was cut
    half=$(( MAX_OUT / 2 ))
    out=$(head -c "$half" "$TMP/out" | tr -d '\0')
    out+=$'\n'"...[$(( size - MAX_OUT )) bytes truncated]..."$'\n'
    out+=$(tail -c "$half" "$TMP/out" | tr -d '\0')
  else
    out=$(tr -d '\0' <"$TMP/out")
  fi
  out="${out:-(no output)}"
  if (( INTERRUPTED )); then
    note="[interrupted by the user]"
  elif (( rc != 0 )); then
    note="[exit code $rc]"
  fi
  if [[ -n "$note" ]]; then
    out+=$'\n'"$note"
    printf '\033[31m%s\033[0m\n' "$note" >&2
  fi
  TOOL_OUT="$out"
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

# One user turn: call the model, run its tools, repeat until it stops
run_turn() {
  local result msg call id name cmd out
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
      return
    fi

    result=$(assemble)
    if ! msg=$(jq -ce '.message // empty' <<<"$result"); then
      echo "API error:" >&2
      jq -r '(.error // "(no response)")
             | if type == "object" then (.message // tojson) else . end
             | if . == "" then "(no response)" else . end' <<<"$result" >&2
      abort_turn
      return
    fi

    # Save the whole assistant message (keeps tool_calls and any
    # reasoning_content)
    append "$msg"
    # Streamed text is already on screen; a non-streamed reply is not
    [[ "$(jq -r '.streamed' <<<"$result")" == true ]] ||
      jq -r '.content // empty' <<<"$msg"

    # No tool calls -> the model is done with this turn
    [[ "$(jq '.tool_calls // [] | length' <<<"$msg")" -gt 0 ]] || return 0

    while IFS= read -r call; do
      id=$(jq -r '.id' <<<"$call")
      name=$(jq -r '.function.name' <<<"$call")
      # arguments is normally a JSON *string*, but some backends send an object
      cmd=$(jq -r '(.function.arguments
                    | if type == "string" then fromjson? else . end
                    | .command?) // empty' <<<"$call")
      if (( INTERRUPTED )); then
        out="Skipped: the user interrupted."
      elif [[ "$name" != "bash" ]]; then
        out="Error: unknown tool '$name'. The only tool is 'bash'."
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
      return
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
              load_session "$arg" || true
            fi ;;
    /about) about ;;
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
done

[[ -f "$(session_file)" ]] &&
  echo "Session saved. Resume with: agent.sh -c  (or -r $SESSION_ID)" >&2
exit 0
