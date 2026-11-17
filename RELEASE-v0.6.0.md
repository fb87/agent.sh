# agent.sh v0.6.0

This release moves agent.sh to the Responses API and gives the model a plan.
Every request now goes to `/responses`; the `/chat/completions` endpoint and
the code that juggled both are gone. The new `todo` tool and `/todo` command
keep a task with several steps as a visible list. Still one bash file, `jq`
and `curl`.

```sh
./agent.sh                     # REPL
./agent.sh "fix the tests"     # one-shot
```

## Highlights

- **The Responses API only.** `opencode`, `openai`, `openrouter` and
  `ollama` now point at `<base>/responses`, and `url` has to end in
  `/responses`; a URL ending in `/chat/completions` is moved over on the way
  in. The reply is converted to chat-shaped chunks before it reaches the
  session, so the rest of agent.sh (tools, sessions, compaction) is unchanged.
- **The `todo` tool.** The model keeps a plan for a task with several steps
  as a list of pending, in progress and done items. The list is shown as it
  changes, saved with the session and carried through compaction; `/todo` (or
  `/todo clear`) shows or clears it.
- **`/btw`.** A side question is answered from the conversation so far, with
  no tools, and neither question nor answer is added to the history or saved
  with the session; `/btw!` asks without the history.
- **Breaking:** endpoints that only serve `/chat/completions`, and models an
  endpoint offers only there, can no longer be used. The per-request fallback
  and the list of models that needed `/responses` went with it, so
  `AGENT_RESPONSES_MODELS` is now ignored.

Everything from [v0.5.0](RELEASE-v0.5.0.md) is still there: plugins, the
built-in providers and GitHub Copilot sign-in, prompt commands, plan and
build modes, `explore` sub-agents, `AGENTS.md`, sessions and compaction, the
Nix flake and module, and JSON configuration.

## Upgrading

- A `url` in the config file or in `URL` that ends in `/chat/completions` is
  rewritten to `/responses`; any other URL must end in `/responses`.
- `AGENT_RESPONSES_MODELS` has no effect; it can be deleted.
- A model that only exists at `/chat/completions` needs an endpoint or
  gateway that serves it at `/responses`.

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

See [CHANGELOG.md](CHANGELOG.md#060---2026-11-17).

## License

MIT — see [LICENSE](LICENSE).
