# agent.sh

A coding agent in a single bash file. One script, `jq` and `curl`; it talks to
OpenAI-compatible chat-completions endpoints — OpenCode Go by default, with
GitHub Copilot, OpenAI, OpenRouter and Ollama built in — and can inspect, edit
and run things in the current directory. Shell plugins can add commands, tools,
providers and hooks.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
./agent.sh --plan          # inspect only, no edits
```

There are two modes: build (the default) edits files and runs commands; plan
only inspects. In build mode the model can also start read-only `explore`
sub-agents to search the project in parallel, and it has `read`, `edit` and
`write` tools for files plus `web_search` and `web_fetch` for the web.

## Install

### Nix and NixOS

Run it straight from the flake:

```sh
nix run github:fb87/agent.sh
```

Or install it into a profile:

```sh
nix profile install github:fb87/agent.sh
```

The package installs `agent.sh` together with its prompts and puts `bash`,
`jq` and `curl` on the wrapper's `PATH`. The flake also provides
`packages.<system>.default`, `apps.default`, `overlays.default`, a dev shell,
and a NixOS module:

```nix
{
  inputs.agent-sh.url = "github:fb87/agent.sh";

  # in your nixosSystem modules:
  imports = [ inputs.agent-sh.nixosModules.default ];

  programs.agent-sh = {
    enable = true;
    # Optional, written to /etc/agent.sh/config.json. Do not put an API key
    # here: that file is world-readable.
    settings = {
      provider = "opencode";
      model = "deepseek-v4.1-flash";
    };
  };
}
```

### Anywhere else

```sh
install -Dm755 agent.sh ~/.local/bin/agent.sh
```

Put prompt overrides in `~/.config/agent.sh/prompts/` (see below). The script
needs `bash`, `jq` and `curl`; if `jq` or `curl` is missing and Nix is
installed, it is taken from the Nix store instead.

## Configuration

Settings are read in increasing priority from:

1. built-in defaults,
2. `/etc/agent.sh/config.json` (system-wide; optional),
3. `$XDG_CONFIG_HOME/agent.sh/config.json` (`~/.config/agent.sh/config.json`),
4. environment variables.

An example user config:

```json
{
  "provider": "opencode",
  "model": "deepseek-v4.1-flash",
  "api_key": "sk-...",
  "reasoning": "low",
  "thinking": "off",
  "temperature": 0.2,
  "providers": {
    "work": {
      "url": "https://llm.example.com/v1/chat/completions",
      "model": "gpt-4.1-mini",
      "api_key": "sk-work-..."
    },
    "openrouter": { "api_key": "sk-or-..." }
  }
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `provider` | `opencode` | provider to use (see [Providers](#providers)) |
| `model` | the provider's default | model name |
| `url` | the provider's endpoint | full chat-completions URL |
| `api_key` | unset | API key; keep the file at mode `0600` |
| `reasoning` | the provider's default | `minimal`, `low`, `medium`, `high` or `default` |
| `thinking` | server default | `on`, `off` or `default` |
| `temperature` | server default | number from `0` to `2` |
| `providers` | `{}` | per-provider `url`, `model`, `api_key` and `reasoning`; a name that is not built in adds a provider |

The top-level `provider`, `model`, `url`, `api_key`, `reasoning`, `thinking`
and `temperature` belong together: `model`, `url`, `api_key` and `reasoning`
apply to the provider that `provider` names at startup. Switching provider in
the REPL (`/provider use`) uses only the new provider's own key and settings,
so one provider's key is never sent to another endpoint; agent.sh says so when
it ignores a top-level value. Inside `providers`, a field in the user's file
wins over the same field in the system file, and the remaining fields still
come from the system file.

The environment wins over the files: `AGENT_API_KEY`, the provider's own key
variable (e.g. `OPENAI_API_KEY`), `MODEL`, `PROVIDER`, `URL`, `REASONING`,
`THINKING`, `TEMPERATURE`. Other knobs are still environment-only; run
`agent.sh -h` for the rest.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTO` | `0` | `1` runs commands without asking (same as `-y`) |
| `MODE` | `build` | `build` or `plan` |
| `PROVIDER` | `opencode` | provider to use (see [Providers](#providers)) |
| `AGENT_PLUGINS` | unset | plugin files and directories, colon-separated; `none` loads none (see [Plugins](#plugins)) |
| `CLI_HINTS` | `1` | `0` stops telling the model about `rg`, `fd`, `fzf`, `ast-grep` and `tree` |
| `AGENT_RESPONSES_MODELS` | unset | `provider/model` pairs that need `/responses`, space-separated |
| `MAX_OUT` | `20000` | tool output bytes sent to the model |
| `READ_LINES` | `400` | lines the `read` tool returns at most |
| `WEB` | `1` | `0` removes `web_search` and `web_fetch` |
| `WEB_TIMEOUT` | `30` | seconds one web call may take |
| `SEARXNG_URL` | unset | SearXNG server for `web_search` |
| `AUTO_COMPACT` | `1` | `0` turns automatic compaction off |
| `CONTEXT` | `0` | model context window in tokens; `COMPACT_AT` then defaults to half of it (4 bytes per token) |
| `COMPACT_AT` | half of `CONTEXT`, else `100000` | history bytes that trigger it |
| `TIMEOUT` | `300` | seconds of API silence before giving up |
| `CMD_TIMEOUT` | `600` | seconds one command may run (`0` = no cap) |
| `OUTSIDE` | `ask` | commands outside the workspace: `ask`, `allow` or `deny` |
| `WORKSPACE` | git root, else `$PWD` | directory commands may use without a question |
| `ALLOW_PATHS` | unset | extra directories that need no question, colon-separated |
| `ASK_CMDS` | `sudo su doas pkexec dd …` | programs that always need approval (`""` = none) |
| `MAX_STEPS` | `0` | tool rounds per turn (`0` = no limit) |
| `PROJECT_DOC` | `1` | `0` stops `./AGENTS.md` joining the system prompt |
| `SUBAGENTS` | `1` | `0` removes the `explore` tool |
| `SUB_MAX` | `4` | explorers running at the same time |
| `SUB_TIMEOUT` | `300` | seconds one explorer may take (`0` = no cap) |
| `SUB_MAX_STEPS` | `25` | tool rounds one explorer may use |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions are saved |
| `AGENT_HISTFILE` | `~/.agent_sh_history` | readline history file |
| `AGENT_HISTORY_MAX` | `1000` | lines kept in that file |
| `PROMPT_DIR` | unset | explicit prompt directory |
| `PROMPT_PATH_MAX` | `32` | width of the directory shown (long paths are cut from the left) |
| `PROMPT_GIT` | `1` | `0` hides the git branch (`*` = uncommitted changes) |
| `PROMPT_MODEL` | `0` | `1` adds the model to the prompt |
| `PROMPT_CONTEXT` | `1` | `0` hides the history size against `COMPACT_AT` |
| `AGENT_CONFIG` | `$XDG_CONFIG_HOME/agent.sh/config.json` | user config file |
| `AGENT_CONFIG_DIR` | `$XDG_CONFIG_HOME/agent.sh` | config directory |
| `AGENT_SYSTEM_CONFIG` | `/etc/agent.sh/config.json` | system config file |

## Providers

`PROVIDER` (or the `provider` config key) picks the endpoint. These are built
in:

| Provider | Endpoint | Default model | Notes |
| --- | --- | --- | --- |
| `opencode` (`opencode-go`) | `https://opencode.ai/zen/go/v1/chat/completions` | `deepseek-v4.1-flash` | default; reasoning `low` |
| `copilot` (`github-copilot`) | GitHub Copilot API | `gpt-4.1` | sign in with GitHub, see below |
| `openai` | `https://api.openai.com/v1/chat/completions` | `gpt-4.1-mini` | |
| `openrouter` | `https://openrouter.ai/api/v1/chat/completions` | `openai/gpt-4.1-mini` | |
| `ollama` | `http://localhost:11434/v1/chat/completions` | `qwen2.5-coder:7b` | local, needs no key |

The models are only starting points; `/model list` shows what the endpoint
really offers, and `model` and `reasoning` in the config file or the
environment override the default of the provider they belong to.

The key is looked up in this order: `AGENT_API_KEY`, the provider's own
variable (`OPENCODE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`), its
entry under `providers` in the config file, a key a plugin provides, and at
startup the top-level `api_key`. `ollama` needs none. A provider's key is
never sent to another endpoint, so `/provider use` uses only the new
provider's own key and settings.

A name that is not built in is read from the `providers` object of the config
file; that also overrides the endpoint, model or key of a built-in one:

```json
{
  "providers": {
    "work": {
      "url": "https://llm.example.com/v1/chat/completions",
      "model": "gpt-4.1-mini",
      "api_key": "sk-work-...",
      "reasoning": "medium"
    }
  }
}
```

`/provider` (or `/provider info`) shows the provider, model, endpoint and
where the key came from. `/provider list` lists every provider this run can
use, with `*` on the current one and whether it is ready. `/provider use NAME
[MODEL]` switches for this run; the conversation carries over, the model does
not (ids differ between providers). It warns when the new endpoint is not
`https`.

Some endpoints serve a model only at `/responses` (the Responses API) and not
at `/chat/completions`. agent.sh tries both, remembers which one the model
needed and goes straight there next time; `/about` shows it. The list is kept
in `AGENT_RESPONSES_MODELS` as space-separated `provider/model` pairs and is
passed on to explorers.

### GitHub Copilot

`agent.sh --login copilot` (or `/login copilot` in the REPL) signs in with
GitHub's device flow: it prints a URL and a code to enter there. The sign-in
token is kept in `$XDG_CONFIG_HOME/agent.sh/auth.json` (mode `0600`, directory
`0700`) and exchanged for a short-lived session token for each request. A
token from `COPILOT_GITHUB_TOKEN`, or the one of the Copilot plugin for
Vim/Neovim, works too. `/login copilot` then switches the REPL to `copilot`;
`--login` signs in and exits, so the next start can use `/provider use copilot`.

## Tools

Besides `bash`, build mode gives the model three file tools and two web
tools. `read` prints a file with line numbers (at most `READ_LINES` lines)
and refuses binaries; reading inside the workspace needs no approval. `edit`
replaces an exact string in a file and `write` creates or replaces one: both
show a diff and ask first; a path outside the workspace needs approval too.
Plan mode refuses all three.

`web_search` returns titles, URLs and snippets, and `web_fetch` turns a page
into text. They search with Brave (`BRAVE_API_KEY`), Tavily
(`TAVILY_API_KEY`) or a SearXNG server (`SEARXNG_URL`) when configured, else
with DuckDuckGo's HTML page, which needs no key but may refuse automated
requests. `WEB=0` removes both tools, and `WEB_TIMEOUT` bounds one fetch or
search. The keys can also be `brave_api_key`, `tavily_api_key` and
`searxng_url` in the config file.

When `rg`, `fd`/`fdfind`, `fzf`, `ast-grep` or `tree` is installed, the system
prompt tells the model to use it in place of `grep -r` or `find`: `rg PATTERN`
instead of `grep -r`, `fd` instead of `find`, `fzf --filter TEXT` (never
without `--filter`; there is no terminal), `ast-grep -p` for syntax-aware
search and `tree -L 2 --gitignore` for a directory layout. `CLI_HINTS=0`
turns this off. `bat` is deliberately not suggested: the `read` tool is
better for the model.

## Sub-agents

In build mode the model can call an `explore` tool. Each call starts a separate
`agent.sh` that may only inspect the project and then returns a report. An
explorer does not see the main conversation, so it is given a self-contained
task. Several explorers run in parallel (up to `SUB_MAX` at once); the turn
waits for their reports and continues when they are done.

Explorers are ordinary read-only agents: they use the same configuration, and
`EXPLORE.md` (see below) replaces the instructions they get. `SUBAGENTS=0`
removes the tool entirely.

## Prompts

`SYSTEM.md`, `COMPACTION.md`, `PLAN.md` and `EXPLORE.md` are looked up per
file, and the first non-blank one wins:

1. `$PROMPT_DIR` (if set),
2. `$XDG_CONFIG_HOME/agent.sh/prompts/`,
3. `<install dir>/pro.mpts/`,
4. the built-in prompt.

So you can override just `SYSTEM.md` and keep the bundled `PLAN.md`. A blank
file falls through to the next location. `{{cwd}}` in a prompt is replaced by
the working directory. Package installs ship `pro.mpts` beside the real
script; check `/about` to see which file each prompt came from.

An `AGENTS.md` in the working directory is added to the system prompt, so
project-specific instructions apply automatically. It is capped at 20 KB;
`PROJECT_DOC=0` turns this off. `/about` shows whether one was used.

A file `commands/NAME.md` in a prompt directory adds a prompt command:
`/NAME` sends that file as the prompt. An HTML comment on the first line is
the description `/help` shows next to it. `{{args}}` is replaced by the text
after the name; when the file has no `{{args}}`, that text is appended.

These prompt commands are bundled; a file of the same name in your own prompt
directory replaces one:

| Command | Purpose |
| --- | --- |
| `/review [what]` | review the uncommitted changes, or a commit, branch or path |
| `/security [what]` | look for security problems in the changes or a path |
| `/explain [what]` | explain a file, a function or the whole project |
| `/debug problem` | find the cause of a problem without changing code |
| `/fix [problem]` | reproduce a bug or failing command, then fix it |
| `/test [what]` | write tests in the project's own style |
| `/refactor [what]` | simplify code without changing what it does |
| `/docs [what]` | bring the documentation in line with the code |
| `/commit` | commit the current changes with a fitting message |
| `/init` | write an `AGENTS.md` for the project |

On the first run, `agent.sh` creates `$XDG_CONFIG_HOME/agent.sh/prompts/` and
copies the bundled prompts into it as `NAME.md.example`. Rename one to
`NAME.md` to override that prompt; the `.example` files themselves never
shadow the bundled prompts. The directory is only created once; existing files
are never overwritten.

## Plugins

A plugin is a bash file sourced into `agent.sh` at startup. Put `*.sh` files
in `$XDG_CONFIG_HOME/agent.sh/plugins/`, or name files and directories in
`AGENT_PLUGINS` (colon-separated; `AGENT_PLUGINS=none` loads none). A plugin
runs as trusted code with the full reach of the script, so only install ones
you have read. A file or directory that anybody can write to, or that belongs
to another user, is not loaded; a plugin that fails to load is reported and
skipped.

At load time a plugin only registers what it adds:

| Call | Adds |
| --- | --- |
| `agent_command NAME "help"` | a REPL command `/NAME [args]` that calls `cmd_NAME "args"`; the function may set `AGENT_PROMPT` to send a prompt |
| `agent_tool NAME "what it does" 'PARAMS' [ro]` | a tool for the model that calls `tool_NAME 'JSON arguments'`; its stdout is the result. `PARAMS` is a JSON schema object; `ro` marks the tool usable in plan mode |
| `agent_provider NAME` | a provider whose `provider_NAME` sets `P_URL`, `P_MODEL` and optionally `P_REASONING`, `P_KIND` and `P_KEY` |
| `agent_hook EVENT FUNC` | a function that runs at `EVENT` (see below) |

For a provider, `P_KIND=local` means it needs no key and `P_KIND=copilot` uses
the Copilot sign-in. `provider_NAME_headers` may print extra request headers,
and `provider_NAME_prepare` runs before each request: a non-zero status fails
the call, and `PLUGIN_ERR` says why.

The hooks are `start` (once after loading), `turn_start TEXT` (a turn begins,
with the text the user typed), `turn_end OK` (a turn ends; `OK` is `1` on
success), `exit` (the REPL quits), and `tool_call NAME ARGS` (before a tool
runs, with its JSON arguments; a non-zero status blocks the call and stdout is
the reason shown to the model).

Names are lower case letters, digits and `_`; a built-in name cannot be taken.
A plugin tool that is not `ro` asks for confirmation like a command (unless
`-y`), plan mode only allows `ro` tools, and an explorer (`SUBAGENTS`) does not
run hooks. `/plugins` lists the files loaded and what each added; `/help`
lists plugin commands next to the built-in ones.

A small plugin in `~/.config/agent.sh/plugins/todo.sh`:

```sh
agent_tool todo "list the TODO comments in the project" \
  '{"type": "object", "properties": {}}' ro

tool_todo() {
  rg -n 'TODO' . || true
}

agent_command stamp "start a prompt with the current date"

cmd_stamp() {
  AGENT_PROMPT="The date is $(date +%F). $*"
}
```

## Usage

| Command | Purpose |
| --- | --- |
| `/about` | version, config, provider/model, endpoint, prompts, sessions |
| `/model` | show model settings |
| `/model list` | list the models the endpoint offers (current one marked) |
| `/model use <id>` | switch model by number or name, for this run |
| `/model set <key> <value>` | change one setting for this run (`model`, `reasoning`, `thinking`, `temperature`, `context`, `compact_at`) |
| `/provider` | the current provider, model and key source (same as `/provider info`) |
| `/provider list` | list the providers and whether each is ready (current one marked) |
| `/provider use <name> [model]` | switch provider (and optionally model) for this run |
| `/login copilot` | sign in to GitHub Copilot, then switch to it |
| `/context` | show the context window and the compaction threshold |
| `/context <tokens\|default>` | set the window in tokens (`default`: unset) |
| `/context compact <bytes\|default>` | set the compaction threshold itself |
| `/plugins` | list the plugin files and what each one added |
| `/compact` | summarize the history (also automatic past `COMPACT_AT`) |
| `/sessions [all]` | list saved sessions |
| `/resume ID` | switch to a session by id or unique prefix |
| `/reset` | start a new session |
| `/auto` | toggle command confirmation |
| `/plan` / `/build` | switch between read-only and editing modes |
| `/exit` | quit (or Ctrl-D) |

Flags: `-y` (run commands without asking, except the ones below), `-p`/`--plan`
and `-b`/`--build` (the last one wins), `-i` (stay in the REPL after a prompt),
`-c`, `-r ID`, `-l [all]`, `--login [copilot]`, `-h`, `-V`. A prompt on the
command line is answered and the agent exits; if the turn fails, the exit
status is non-zero, so one-shot runs can be used from scripts. `--` ends
option parsing. `--login [copilot]` signs in to GitHub Copilot and exits (see
[GitHub Copilot](#github-copilot)); in the REPL, `/login copilot` signs in and
switches to it.

Sessions are JSON files under `~/.local/state/agent.sh/sessions`; `-c`
continues the latest in the current directory, `-r ID` resumes one, `-l [all]`
lists them. A fresh session (no `-c`/`-r`) starts with the `/about` card.
Besides the history, a session keeps the provider, model, reasoning, thinking
and temperature, plus the context window and its compaction threshold; these
are saved after each turn and restored by `-c` and `-r`. API keys and URLs are
never saved. A provider is restored only if it still resolves, and values set
in the environment for this run are kept.

A command is stopped after `CMD_TIMEOUT` seconds when `timeout` is available.
Commands the model runs do not inherit the API key, and state files are
created private.

## Approval and the workspace

The workspace is the git repository that contains the starting directory, or
that directory when there is no repository. A command that names a path
outside it (an absolute path, `~`, `$HOME`, or one that climbs with `..`)
needs your approval every time, also under `-y`. Common read-only system
locations (`/usr`, `/nix/store`, `/tmp`, ...) and anything in `ALLOW_PATHS`
are exempt. `OUTSIDE=allow` turns the question off and `OUTSIDE=deny` refuses
such commands instead.

Dangerous commands are treated the same way: a program in `ASK_CMDS` in
command position (`sudo`, `dd`, `reboot`, ...; `ASK_CMDS=""` empties the
list), a forced push, a hard reset, `git clean -f`, or a download piped into
a shell.

The config directory (`~/.config/agent.sh`, where the key, the sign-in token
and the plugins live) is never free: a command that names it asks for
approval even when it is inside the workspace. A plugin file is not loaded
when it or its directory is world-writable or owned by another user.

The prompt offers `a` for "always this session", which allows either kind of
command for the rest of the run; `OUTSIDE` and `ASK_CMDS` set up front do the
same. This all reads the command text only, so it is a seat belt, not a
sandbox: a script, a path built at run time or a symbolic link can still go
elsewhere.

## Development

```sh
nix develop        # bash, jq, curl, shellcheck
nix build          # ./result/bin/agent.sh
nix flake check    # builds it and lints agent.sh with shellcheck
```

## License

MIT — see [LICENSE](LICENSE). Changes are in [CHANGELOG.md](CHANGELOG.md).
