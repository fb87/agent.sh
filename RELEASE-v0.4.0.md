# agent.sh v0.4.0

This release gives the model hands: tools to read, edit and write files, and to
search and fetch the web. Prompt commands let you put your own `/NAME` entries
in the REPL. Still one bash file, `jq` and `curl`.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
./agent.sh --plan          # inspect only, no edits
```

## Highlights

- **File tools.** `read` prints a file with line numbers (at most `READ_LINES`
  lines, 400 by default) and refuses binaries; reading inside the workspace
  needs no approval. `edit` replaces an exact string, `write` creates or
  replaces a file. Both show a diff and ask before touching anything and
  create missing directories; a path outside the workspace needs approval,
  as with commands. Plan mode refuses all three.
- **Web tools.** `web_search` returns titles, URLs and snippets; `web_fetch`
  turns a page into text. Search uses Brave (`BRAVE_API_KEY`), Tavily
  (`TAVILY_API_KEY`) or a SearXNG server (`SEARXNG_URL`) when configured, else
  DuckDuckGo's HTML page, which needs no key but may refuse automated
  requests. `WEB=0` removes both tools, `WEB_TIMEOUT` (30 s) bounds one call,
  and the keys can also live in `config.json`.
- **Prompt commands.** A file `commands/NAME.md` in a prompt directory becomes
  `/NAME` in the REPL: it sends that file as the prompt, and text typed after
  the name replaces `{{args}}` (or is appended). An HTML comment on the first
  line is the description `/help` shows. Prompts now also understand
  `{{workspace}}`, `{{os}}` and `{{date}}` beside `{{cwd}}`.
- **`/model list` and `/model use`.** The REPL asks the endpoint which models
  it offers, marks the current one, and switches by number or name for this
  run. A name that is not in the list is still sent, with a warning, so
  private and alias names keep working.
- **`CONTEXT`.** Set the model's context window in tokens and `COMPACT_AT`
  defaults to half of it (4 bytes per token), instead of one hardcoded byte
  threshold for every model. `/model` shows both, and a `COMPACT_AT` past the
  window produces a warning.
- **Shellcheck in the flake check.** `nix flake check` now lints `agent.sh`,
  so the quoting, `eval` and word-splitting findings behind most script
  security bugs are caught instead of being an optional local habit.
- **Hardening.** A warning when the endpoint is not `https` and not localhost;
  strict validation of numeric settings, `0`/`1` flags and session ids; plan
  mode refuses more repository-changing git options and no longer treats
  `git ls-remote` as read-only; explorers never ask for approval; terminal
  text is sanitized and paths are resolved through symlinks before a
  directory is created.

Everything from [v0.3.0](RELEASE-v0.3.0.md) is still there: plan and build
modes, `explore` sub-agents, `AGENTS.md`, prompt overrides, approval for risky
commands, sessions and compaction, the Nix flake and module, and JSON
configuration.

## Requirements

`bash`, `jq`, `curl`. Web search works out of the box through DuckDuckGo's
HTML page; an API key or `SEARXNG_URL` makes it more reliable.

## Configuration

Settings come from built-in defaults, `/etc/agent.sh/config.json`,
`~/.config/agent.sh/config.json` and the environment, in that order.
Frequently used knobs:

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_API_KEY` | unset | API key (`OPENCODE_API_KEY` also works) |
| `MODEL` | `deepseek-v4.1-flash` | model to call |
| `REASONING` | `low` | reasoning effort (`""` = omit the field) |
| `THINKING` | unset | `on`/`off` (`""` = server default) |
| `TEMPERATURE` | unset | `0`..`2` (`""` = server default) |
| `URL` | OpenCode Go chat completions | OpenAI-compatible endpoint |
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
| `AUTO_COMPACT` | `1` | summarize a long history automatically |
| `COMPACT_AT` | see `CONTEXT` | history bytes that trigger it |
| `TIMEOUT` | `300` | seconds of silence before giving up |
| `CMD_TIMEOUT` | `600` | seconds one command may run (`0` = no cap) |
| `MAX_STEPS` | `0` | tool rounds per turn (`0` = no limit) |
| `SUBAGENTS` | `1` | `0` removes the `explore` tool |
| `SUB_MAX` | `4` | explorers running at the same time |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions live |
| `PROMPT_DIR` | unset | explicit prompt directory |

## Full changelog

See [CHANGELOG.md](CHANGELOG.md#040---2026-11-15).

## License

MIT — see [LICENSE](LICENSE).
