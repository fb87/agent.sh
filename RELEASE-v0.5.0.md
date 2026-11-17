# agent.sh v0.5.0

This release makes agent.sh easier to extend and lets it talk to more than one
place. Shell plugins add commands, tools, providers and hooks; GitHub Copilot,
OpenAI, OpenRouter and Ollama are built-in providers next to OpenCode Go; and
the REPL can set the context window and compaction threshold while a session
remembers its provider. Still one bash file, `jq` and `curl`.

```sh
./agent.sh                     # REPL
./agent.sh --login copilot     # sign in to GitHub Copilot
./agent.sh "fix the tests"     # one-shot
```

## Highlights

- **Plugins.** `*.sh` files in `$XDG_CONFIG_HOME/agent.sh/plugins`, and the
  files and directories in `AGENT_PLUGINS` (colon-separated, `none` loads
  none), are sourced at startup as trusted code. They add REPL commands
  (`agent_command`), tools for the model (`agent_tool`, read-only or confirmed
  before use), providers (`agent_provider`, with optional extra headers and a
  preparation step) and hooks (`agent_hook`) at `start`, `turn_start`,
  `turn_end`, `exit` and `tool_call`. Built-in names stay reserved, plugin
  commands show up in `/help`, and `/plugins` lists the files and what each one
  added. A file that is world-writable or owned by another user is not loaded,
  and a file that fails to load is reported and skipped.
- **More providers.** `copilot` (GitHub Copilot), `openai`, `openrouter` and
  `ollama` join `opencode`; `PROVIDER` picks one. The new `providers` object in
  `config.json` sets a model, key or endpoint per provider and can add a
  provider of your own. `/provider`, `/provider list` and
  `/provider use NAME [MODEL]` show where the key comes from, which providers
  are ready, and switch for this run. Each provider has its own default model
  and reasoning effort, and one provider's key is never sent to another.
- **GitHub Copilot sign-in.** `agent.sh --login copilot` runs GitHub's device
  flow and keeps the token in `$XDG_CONFIG_HOME/agent.sh/auth.json` (mode
  `0600`, directory `0700`), then exits; `/login copilot` signs in and switches
  the REPL to it. `COPILOT_GITHUB_TOKEN`, or the token of the Copilot plugin
  for Vim/Neovim, also works.
- **`/context`.** `/context` shows the context window and the compaction
  threshold. `/context N` sets the window in tokens and `/context compact
  BYTES` the threshold itself (`default` restores the automatic value);
  `/model set` accepts `context` and `compact_at` too.
- **`/responses` fallback.** A model that refuses `/chat/completions` and
  accepts `/responses` is remembered and used from then on.
  `AGENT_RESPONSES_MODELS` sets the pairs up front, `/about` shows the list,
  and explorers inherit it.
- **CLI hints.** When `rg`, `fd`, `fzf`, `ast-grep` or `tree` is installed, the
  model is told to use it instead of `grep -r` and `find`. `CLI_HINTS=0` turns
  the hints off.
- **Sessions** now save the provider, model, reasoning, thinking, temperature,
  context and compaction threshold after each turn, and `-c`/`-r` restore them.
  Keys and URLs are not saved, values set in the environment for this run are
  kept, and a provider is restored only if it still resolves.

Everything from [v0.4.0](RELEASE-v0.4.0.md) is still there: file and web
tools, prompt commands, plan and build modes, `explore` sub-agents,
`AGENTS.md`, approval for risky commands, sessions and compaction, the Nix
flake and module, and JSON configuration.

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
| `URL` | the provider's endpoint | full chat-completions URL |
| `REASONING` | the provider's default | reasoning effort (`""` = omit the field) |
| `THINKING` | unset | `on`/`off` (`""` = server default) |
| `TEMPERATURE` | unset | `0`..`2` (`""` = server default) |
| `AGENT_PLUGINS` | unset | plugin files and directories, colon-separated; `none` loads none |
| `CLI_HINTS` | `1` | `0` stops telling the model about the fast CLI tools |
| `AGENT_RESPONSES_MODELS` | unset | `provider/model` pairs that need `/responses` |
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

See [CHANGELOG.md](CHANGELOG.md#050---2026-11-17).

## License

MIT — see [LICENSE](LICENSE).
