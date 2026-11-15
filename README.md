# agent.sh

A coding agent in a single bash file. One script, `jq` and `curl`; it talks to
an OpenAI-compatible chat-completions endpoint and can inspect, edit and run
things in the current directory.

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
  "temperature": 0.2
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `provider` | `opencode` | `opencode`/`opencode-go` picks the default endpoint |
| `model` | `deepseek-v4.1-flash` | model name |
| `url` | provider's endpoint | full chat-completions URL for any provider |
| `api_key` | unset | API key; keep the file at mode `0600` |
| `reasoning` | `low` | `minimal`, `low`, `medium`, `high` or `default` |
| `thinking` | server default | `on`, `off` or `default` |
| `temperature` | server default | number from `0` to `2` |

The environment wins over the files: `AGENT_API_KEY` (or the older
`OPENCODE_API_KEY`), `MODEL`, `PROVIDER`, `URL`, `REASONING`, `THINKING`,
`TEMPERATURE`. Other knobs are still environment-only; run `agent.sh -h` for
the rest.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTO` | `0` | `1` runs commands without asking (same as `-y`) |
| `MODE` | `build` | `build` or `plan` |
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

On the first run, `agent.sh` creates `$XDG_CONFIG_HOME/agent.sh/prompts/` and
copies the bundled prompts into it as `NAME.md.example`. Rename one to
`NAME.md` to override that prompt; the `.example` files themselves never
shadow the bundled prompts. The directory is only created once; existing files
are never overwritten.

## Usage

| Command | Purpose |
| --- | --- |
| `/about` | version, config, provider/model, endpoint, prompts, sessions |
| `/model` | show model settings |
| `/model list` | list the models the endpoint offers (current one marked) |
| `/model use <id>` | switch model by number or name, for this run |
| `/model set <key> <value>` | change one setting (and only for this run) |
| `/compact` | summarize the history (also automatic past `COMPACT_AT`) |
| `/sessions [all]` | list saved sessions |
| `/resume ID` | switch to a session by id or unique prefix |
| `/reset` | start a new session |
| `/auto` | toggle command confirmation |
| `/plan` / `/build` | switch between read-only and editing modes |
| `/exit` | quit (or Ctrl-D) |

Flags: `-y` (run commands without asking, except the ones below), `-p`/`--plan`
and `-b`/`--build` (the last one wins), `-i` (stay in the REPL after a prompt),
`-c`, `-r ID`, `-l [all]`, `-h`, `-V`. A prompt on the command line is
answered and the agent exits; if the turn fails, the exit status is non-zero,
so one-shot runs can be used from scripts. `--` ends option parsing.

Sessions are JSON files under `~/.local/state/agent.sh/sessions`; `-c`
continues the latest in the current directory, `-r ID` resumes one, `-l [all]`
lists them. A fresh session (no `-c`/`-r`) starts with the `/about` card.

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
