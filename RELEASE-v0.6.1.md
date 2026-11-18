# agent.sh v0.6.1

This release makes sessions easier to keep apart and mode switches lose less
work. `/tmp on` forks a side session that is never saved, one session belongs
to each workspace, and `/plan TEXT` / `/build TEXT` switch mode and send the
prompt in the same step — with a note that tells the model the plan is still
in the conversation. `/btw` is gone. Still one bash file, `jq` and `curl`.

```sh
./agent.sh                     # REPL
./agent.sh --new               # start over in this workspace
./agent.sh "fix the tests"     # one-shot
```

## Highlights

- **Temporary sessions.** `/tmp on` forks the current conversation into a
  session that is not saved; `/tmp off` goes back to the one you came from.
  The prompt shows `tmp` while it is on. Switching session (`/reset`,
  `/resume`) needs `/tmp off` first, so a side trip cannot eat the main
  session.
- **One session per workspace.** Starting in a directory that already has a
  session asks whether to resume it, start a new one or cancel; `--new` skips
  the question, and a one-shot prompt does not save anything. The session it
  replaces is kept as a backup rather than overwritten.
- **`/plan TEXT` and `/build TEXT`.** The switch and the prompt are one step,
  so leaving plan mode can start the work immediately. Only the system prompt
  changes when the mode changes: everything read while planning stays in the
  conversation, and going from plan to build the next prompt carries a note
  telling the model to carry out the plan instead of reading the project
  again. A mere `/plan` / `/build` still just switches.
- **A sharper plan prompt.** The model is asked to read the files it plans to
  change itself (explorers report back but leave the files out of the
  conversation) and to name the functions and lines, so the plan can be
  carried out without looking at the code again.
- **`/reset` asks first** and keeps the session it replaces as a backup.

## Removed

- `/btw`. For a question that should not be saved, use `/tmp on`, ask, then
  `/tmp off`.

Everything from [v0.6.0](RELEASE-v0.6.0.md) is still there: the Responses API
only, the `todo` tool, plugins, the built-in providers and GitHub Copilot
sign-in, prompt commands, plan and build modes, `explore` sub-agents,
`AGENTS.md`, sessions and compaction, the Nix flake and module, and JSON
configuration. The [user manual](MANUAL.md) documents all of it.

## Upgrading

Nothing to change: no flag, setting or session format moved. `/btw` is gone,
and a new session is offered when the workspace already has one.

## Requirements

`bash`, `jq`, `curl`. Web search works out of the box through DuckDuckGo's
HTML page; an API key or `SEARXNG_URL` makes it more reliable.

## Configuration

Settings come from built-in defaults, `/etc/agent.sh/config.json`,
`~/.config/agent.sh/config.json` and the environment, in that order.
Frequently used knobs:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PROVIDER` | `opencode` | provider to use |
| `AGENT_API_KEY` | unset | API key; the provider's own `*_API_KEY` also works |
| `MODEL` | the provider's default | model to call |
| `URL` | the provider's endpoint | Responses API URL, ends in `/responses` |
| `REASONING` | the provider's default | reasoning effort (`""` = omit the field) |
| `THINKING` | unset | `on`/`off` (`""` = server default) |
| `TEMPERATURE` | unset | `0`..`2` (`""` = server default) |
| `AGENT_PLUGINS` | unset | plugin files and directories, colon-separated; `none` loads none |
| `CLI_HINTS` | `1` | `0` stops telling the model about the fast CLI tools |
| `AUTO` | `0` | `1` = run commands without asking |
| `MODE` | `build` | `plan` = read-only commands, no edits |
| `OUTSIDE` | `ask` | outside the workspace: `ask`, `allow`, `deny` |
| `ALLOW_PATHS` | unset | extra directories needing no question |
| `ASK_CMDS` | common system tools | programs that always need approval |
| `MAX_OUT` | `20000` | tool output bytes sent back to the model |
| `READ_LINES` | `400` | lines the `read` tool returns at most |
| `WEB` | `1` | `0` removes `web_search` and `web_fetch` |
| `WEB_TIMEOUT` | `30` | seconds one web call may take |
| `SEARXNG_URL` | unset | SearXNG server for `web_search` |
| `CONTEXT` | `0` | context window in tokens (`0` = unset) |
| `COMPACT_AT` | half of `CONTEXT`, else `100000` | history bytes that trigger compaction |
| `AUTO_COMPACT` | `1` | summarize a long history automatically |
| `TIMEOUT` | `300` | seconds of API silence before giving up |
| `CMD_TIMEOUT` | `600` | seconds one command may run (`0` = no cap) |
| `MAX_STEPS` | `0` | tool rounds per turn (`0` = no limit) |
| `SUBAGENTS` | `1` | `0` removes the `explore` tool |
| `SUB_MAX` | `4` | explorers running at the same time |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions live |
| `PROMPT_DIR` | unset | explicit prompt directory |

## Full changelog

See [CHANGELOG.md](CHANGELOG.md#061---2026-11-19).

## License

MIT — see [LICENSE](LICENSE).
