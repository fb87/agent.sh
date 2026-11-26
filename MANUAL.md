# agent.sh — user manual

`agent.sh` is a coding agent in a single bash file. It needs `bash`, `jq` and
`curl`, talks to endpoints that speak the OpenAI **Responses API** (OpenCode Go
by default, with GitHub Copilot, OpenAI, OpenRouter and Ollama built in), and
can read, edit and run things in the current directory after asking you.

This manual documents the behaviour of `agent.sh` 0.6.1 exactly as the script
implements it. The [README](README.md) is the short tour; where the two differ,
this manual and the script win.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
./agent.sh --plan          # inspect only, no edits
```

Contents

1. [Architecture](#1-architecture)
2. [Installing](#2-installing)
3. [Configuration](#3-configuration)
4. [Providers and models](#4-providers-and-models)
5. [Modes: build and plan](#5-modes-build-and-plan)
6. [Tools](#6-tools)
7. [Sub-agents (explorers)](#7-sub-agents-explorers)
8. [Prompts](#8-prompts)
9. [Plugins](#9-plugins)
10. [Command-line reference](#10-command-line-reference)
11. [The REPL](#11-the-repl)
12. [Sessions](#12-sessions)
13. [Approval and the workspace](#13-approval-and-the-workspace)
14. [Compaction](#14-compaction)
15. [The prompt line, /about, /model and /context](#15-the-prompt-line-about-model-and-context)
16. [Troubleshooting](#16-troubleshooting)
17. [Development](#17-development)
18. [License](#18-license)

---

## 1. Architecture

### One script, three programs

`agent.sh` is a single bash script (`#!/usr/bin/env bash`, `set -euo pipefail`)
with no build step. At runtime it needs:

| Program | Why |
| --- | --- |
| `bash` | it is a bash script |
| `jq` | builds request bodies and parses JSON/SSE |
| `curl` | every HTTP request |

Both `jq` and `curl` are checked with `need` before anything else. If one is
missing, `need` looks for a matching build in the Nix store
(`/nix/store/*-PROG-[0-9]*/bin/PROG`, or `NIX_STORE_DIR` if set); if `nix` is
available it builds `nixpkgs#PROG` and prepends the result to `PATH`, saying
"using PROG from the Nix store"; otherwise it prints install hints
(`apt install` / `dnf install` / `brew install`, or
`nix profile install nixpkgs#PROG`) and exits 1.

Optional programs, used when present:

| Program | Effect when present | When missing |
| --- | --- | --- |
| `timeout` / `gtimeout` | commands are stopped after `CMD_TIMEOUT` seconds | commands run unbounded |
| `setsid` | each command runs in its own process group, so Ctrl-C stops the group | `set -m` is used instead |
| `w3m`, else `lynx` | `web_fetch` renders HTML as readable text | a small `awk` tag stripper is used |
| `rg`, `fd`/`fdfind`, `fzf`, `ast-grep`, `tree` | suggested to the model in the system prompt | the classic tools are not replaced, only not suggested |
| `uuidgen` | session ids | `/proc/sys/kernel/random/uuid`, else `bash-agent-PID-EPOCH` |

`bat`/`batcat` is deliberately *not* suggested (it pages by default).

### Startup order

When the script starts it does, in order:

1. `resolve_self` → `SELF` (symlinks resolved) and `INSTALL_DIR`.
2. `build_prompt_dirs` — the prompt search path.
3. `init_config_dir` — create `$CONFIG_DIR` and its `prompts/*.md.example`
   copies on first run.
4. `load_plugins` — source plugin files.
5. `--login` → `copilot_login` and exit.
6. `load_settings` — system config, user config, environment, `resolve_provider`.
7. `warn_config_permissions` — warn if the config file with an `api_key` is
   readable by others.
8. Determine `START_DIR` (`$PWD`) and `WORKSPACE` (git toplevel, else
   `START_DIR`, unless `WORKSPACE` is set); refuse a workspace that is a
   symlink into the start directory.
9. Compute `OUTSIDE_ALLOW`, `WORKSPACE_PHYS`, `OS_NAME` (`uname -sm`),
   `TODAY` (`date +%Y-%m-%d`).
10. Read the system prompt (`SYSTEM.md` or the built-in), append `AGENTS.md`
    if present and `PROJECT_DOC=1`, add the CLI hints, build the tools JSON.
11. `sandbox_setup` — find or build the Landlock helper and compute the
    rules (see [Sandbox](#sandbox)); when it is on, a paragraph about it is
    appended to the system prompt.
12. Create the scratch directory `$TMP` under `${SESSION_DIR%/*}`
    (`.../agent.sh/run.<pid>.XXXXXX`), removing stale `run.<pid>.*` from the
    same pid; install the exit/signal traps.
13. Find `timeout` and `setsid`, if any.
14. Load or create the session (see [Sessions](#12-sessions)).
15. `apply_mode "$MODE"` — choose the system prompt for build or plan.
16. Run the REPL loop.

On exit the `EXIT` trap kills a running command's process group, kills any
explorer still running, and deletes `$TMP`. `SIGHUP` exits 129; a sub-agent's
`SIGTERM` exits 143.

### The turn loop

A "turn" is one user message and everything the model does in response:

```
run_turn
 └─ call_api            curl to <endpoint>/responses, streaming SSE
     └─ resp2chat       Responses events → chat-style chunks
         └─ show_stream prints text, and reasoning dimmed
 └─ assemble            rebuild the assistant message
 └─ for each tool_call
     ├─ explore         → sub-agent (started first, several in parallel)
     ├─ plugin tool     → tool_NAME in a plugin
     ├─ bash            → run_tool (approval, timeout, output clipping)
     └─ read/edit/write/web_search/web_fetch/todo → tool_NAME
 └─ auto_compact mid    may summarize mid-turn when the history gets long
 └─ MAX_STEPS           at the limit, one last request without tools
```

A turn ends when the model returns no tool calls, when the user interrupts
(Ctrl-C), on an API error, or when `MAX_STEPS` is reached. Ctrl-C sets
`INTERRUPTED`; the partial text is kept with a `[interrupted by the user]`
marker and the turn is marked failed.

### Sub-agents are the same script

An explorer is not a thread: it is a second `agent.sh` process, started with
`AGENT_SUB=1`, a fresh scratch `SESSION_DIR`, `AGENT_HISTFILE=/dev/null`, a
read-only tool set and its own system prompt. The parent writes the task to
`$SUB_DIR/N.task`, runs `timeout SUB_TIMEOUT "$SELF" -- "Task: …"`, and reads
`N.out`. That is why `SUB_*` settings are exported into the child and why
explorers never ask questions or save sessions.

### Security posture

- The key is read into a shell variable and then `unset` from the environment,
  so commands the model runs do not inherit `AGENT_API_KEY` or
  `OPENAI_API_KEY`. `curl` reads it from a temporary header file, not from the
  command line, so it does not show up in `ps`.
- `umask 077` makes new state files private; the user's original umask is
  restored for the commands the model runs and for files written with `write`.
- Config, sessions and auth files are created with owner-only permissions.
- On Linux, commands and the file tools run inside a **Landlock sandbox**
  (see [section 6](#sandbox)): they may write only in the workspace, `$TMPDIR`
  and `~/.cache`, and may not read the rest of the home directory — keys,
  config and sessions included. `SANDBOX_NET=0` removes network access too.
  Where the sandbox is not available (no kernel support, no C compiler to
  build its helper once) agent.sh says so in `/about`, and `SANDBOX=on` makes
  that a startup error instead.
- Without the sandbox, the approval system is a seat belt: it reads the
  command text and the paths it names, so a script, a path built at run time
  or a symbolic link can still go elsewhere. Even with it, everything the
  sandbox allows — the workspace and what you add with `SANDBOX_WRITE` — is
  open to any command, whatever its text says.

---

## 2. Installing

`agent.sh` is one bash file. Installing it is copying that file somewhere on
your `PATH`; the bundled prompts are optional, and Nix is only needed if you
want the packaged version or the NixOS module.

### Linux/Unix

```sh
install -Dm755 agent.sh ~/.local/bin/agent.sh
```

That is all that is required: `bash`, `jq` and `curl` must be installed
(`need` offers to fetch `jq`/`curl` from Nix when they are missing). The
built-in prompts are used unless you override them in
`~/.config/agent.sh/prompts/` (see [First run](#first-run)), so you do not need
the `pro.mpts` tree. `./agent.sh -V` prints `agent.sh 0.6.1` when it starts.

To also get the bundled prompt and prompt-command files, copy `pro.mpts` into
`$INSTALL_DIR/pro.mpts` — the directory the script itself was resolved to,
symlinks followed. A private directory with a symlink into `PATH` keeps the
tree in one place:

```sh
install -Dm755 agent.sh ~/.local/lib/agent.sh/agent.sh
cp -r pro.mpts ~/.local/lib/agent.sh/
ln -sf ~/.local/lib/agent.sh/agent.sh ~/.local/bin/agent.sh
```

`PROMPT_DIR` can point at a `pro.mpts`-style tree anywhere; a file in
`~/.config/agent.sh/prompts/` overrides the bundled copy of the same name (see
[Prompts](#8-prompts)).

### Nix flake

If you use Nix, the flake installs the script together with its prompts and
wraps it so `bash`, `curl` and `jq` are always on `PATH`:

```sh
nix run github:fb87/agent.sh          # run without installing
nix profile install github:fb87/agent.sh
```

The flake exposes `packages.<system>.agent-sh` (and `default`),
`apps.default`, `overlays.default`, `nixosModules.default` (also
`.agent-sh`) for `x86_64-linux`, `aarch64-linux`, `x86_64-darwin` and
`aarch64-darwin`.

The package installs the script as `$out/libexec/agent.sh` together with
`pro.mpts/*.md` and `pro.mpts/commands/*.md`, and wraps it with `bash`, `curl`
and `jq` on `PATH`. `nix flake check` builds the package, runs its
`installCheckPhase` (`agent.sh -V` must print `agent.sh <version>`) and runs
`shellcheck` in the dev shell.

### NixOS module

```nix
{
  inputs.agent-sh.url = "github:fb87/agent.sh";

  # in your configuration
  imports = [ inputs.agent-sh.nixosModules.default ];

  programs.agent-sh = {
    enable = true;
    settings = {
      provider = "opencode";
      model = "deepseek-v4.1-flash";
    };
  };
}
```

| Option | Meaning |
| --- | --- |
| `programs.agent-sh.enable` | add the package to `environment.systemPackages` |
| `programs.agent-sh.package` | which package to install (default: the flake's) |
| `programs.agent-sh.settings` | an attrset written as `/etc/agent.sh/config.json` |

`settings` is serialised with `builtins.toJSON` and only written when it is
not empty. Because `/etc/agent.sh/config.json` is world-readable, never put an
`api_key` there: use `~/.config/agent.sh/config.json` with mode 0600, or
`AGENT_API_KEY`.

### First run

On the first run, when `$CONFIG_DIR` does not exist yet, `agent.sh` creates:

```
~/.config/agent.sh/
├── config.json          (only if you create it)
└── prompts/
    ├── COMPACTION.md.example
    ├── EXPLORE.md.example
    ├── PLAN.md.example
    └── SYSTEM.md.example
```

and prints "agent.sh: created … with the prompts as *.md.example; rename one
to *.md to override it". Rename an example to its `.md` name and edit it to
override that prompt. A fresh session also prints the `/about` card so you can
see what is in effect.

Plugins live in `~/.config/agent.sh/plugins/*.sh`, the Copilot token in
`~/.config/agent.sh/auth.json`, sessions in
`~/.local/state/agent.sh/sessions/`.

---

## 3. Configuration

### Precedence

From strongest to weakest:

1. **Environment variables** (e.g. `PROVIDER=openai ./agent.sh`).
2. **`$CONFIG_FILE`** — `~/.config/agent.sh/config.json`, or `AGENT_CONFIG`.
3. **`$SYSTEM_CONFIG_FILE`** — `/etc/agent.sh/config.json`, or
   `AGENT_SYSTEM_CONFIG`.
4. **Built-in defaults**.

For the *same* provider, the top-level `model`, `url`, `api_key`, `reasoning`
and `thinking` at the top of the user file override those at the top of the
system file; a `providers` entry is filled field by field, system first, with
non-empty user values winning. If the top-level settings name a different
provider than the one selected, they are ignored with a note:

```
note: the model, url, api_key, reasoning and thinking at the top of
~/.config/agent.sh/config.json are for provider "openai", not "opencode";
use "providers" for more
```

An empty environment variable counts as "set to empty" (and, for `MODEL`, is an
error later), because `agent.sh` distinguishes unset from empty.

### The config file

```json
{
  "provider": "opencode",
  "model": "deepseek-v4.1-flash",
  "url": "https://opencode.ai/zen/go/v1/responses",
  "api_key": "sk-…",
  "reasoning": "low",
  "thinking": "on",
  "temperature": 0.2,
  "brave_api_key": "…",
  "tavily_api_key": "…",
  "searxng_url": "https://searx.example.com",
  "providers": {
    "work": {
      "url": "https://llm.example.com/v1/responses",
      "model": "gpt-4.1",
      "api_key": "sk-…",
      "reasoning": "medium"
    }
  }
}
```

The file must be a JSON object; anything else is "Could not read …: it must be
a JSON object" and exit 2.

Read from the file:

| Key | Effect |
| --- | --- |
| `provider` | the provider to use |
| `model` | model for that provider |
| `url` | endpoint for that provider |
| `api_key` | key for that provider |
| `reasoning` | `minimal`, `low`, `medium`, `high`, `default` |
| `thinking` | `on`, `off`, `default` |
| `temperature` | 0–2 |
| `providers` | per-provider `url`, `model`, `api_key`, `reasoning`; new names allowed |
| `brave_api_key`, `tavily_api_key` | web search keys (environment wins) |
| `searxng_url` | SearXNG base URL (environment wins) |

Everything else is **environment-only**. `reasoning`, `thinking` and
`temperature` apply only when the top-level settings are used for the selected
provider; per-provider `reasoning` is supported, per-provider `thinking` and
`temperature` are not.

The top-level `provider`/`model`/`url`/`api_key` belong together: they describe
one provider. To keep settings for several providers, put them under
`providers`. Never commit an `api_key` to a world-readable file; if the user
config contains one and is group- or other-readable, `agent.sh` warns
"warning: … contains an api_key but is readable by others; run chmod 600 on
it".

### Environment variables

Every variable below is read once at startup.

#### Model and provider

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROVIDER` | `opencode` | provider name (built-in or from `providers`) |
| `MODEL` | provider's | model id |
| `URL` | provider's | Responses endpoint |
| `AGENT_API_KEY` | — | key for any provider; wins over the provider-specific one |
| `OPENCODE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` | — | key for that provider |
| `COPILOT_GITHUB_TOKEN` | — | GitHub token for Copilot |
| `REASONING` | provider's | `minimal`, `low`, `medium`, `high`, empty |
| `THINKING` | server | `on`, `off` |
| `TEMPERATURE` | server | 0–2 |
| `CONTEXT` | `0` | model window in tokens (0 = unknown) |
| `TIMEOUT` | `300` | seconds of network silence before giving up |
| `MAX_OUT` | `20000` | bytes of tool output sent to the model |

#### Behaviour

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTO` | `0` | 1 = run tools without asking |
| `MODE` | `build` | `build` or `plan` |
| `AUTO_COMPACT` | `1` | 1 = summarize a long history automatically |
| `COMPACT_AT` | empty | bytes that trigger compaction; empty = `CONTEXT*2`, or `100000` |
| `CMD_TIMEOUT` | `600` | seconds one command may run (0 = no cap) |
| `MAX_STEPS` | `0` | tool rounds per turn (0 = no limit) |
| `SHOW_REASONING` | `1` | 1 = stream reasoning text, dimmed |

#### Tools

| Variable | Default | Meaning |
| --- | --- | --- |
| `READ_LINES` | `400` | lines `read` returns when no limit is given |
| `WEB` | `1` | 0 removes `web_search` and `web_fetch` |
| `WEB_TIMEOUT` | `30` | seconds one fetch or search may take |
| `BRAVE_API_KEY` | — | use Brave for search |
| `TAVILY_API_KEY` | — | use Tavily for search |
| `SEARXNG_URL` | — | use a SearXNG server |
| `BRAVE_URL`, `TAVILY_URL`, `DDG_URL` | vendor URLs | override the endpoints (testing) |
| `CLI_HINTS` | `1` | 0 stops suggesting `rg`/`fd`/`fzf`/`ast-grep`/`tree` |
| `PROJECT_DOC` | `1` | 1 = append `./AGENTS.md` to the system prompt |

#### Sub-agents

| Variable | Default | Meaning |
| --- | --- | --- |
| `SUBAGENTS` | `1` | 0 removes the `explore` tool |
| `SUB_MAX` | `4` | explorers running at the same time |
| `SUB_TIMEOUT` | `300` | seconds one explorer may take |
| `SUB_MAX_STEPS` | `25` | tool rounds one explorer may use |

#### Sessions and history

| Variable | Default | Meaning |
| --- | --- | --- |
| `SESSION_DIR` | `$XDG_STATE_HOME/agent.sh/sessions` | where sessions are saved |
| `SESSION_ID` | new uuid | id for a fresh session (letters, digits, `.`, `_`, `-`) |
| `XDG_STATE_HOME` | `~/.local/state` | base for the session directory |
| `AGENT_HISTFILE` | `~/.agent_sh_history` | readline history file (0600) |
| `AGENT_HISTORY_MAX` | `1000` | lines kept in that file |

#### Paths

| Variable | Default | Meaning |
| --- | --- | --- |
| `XDG_CONFIG_HOME` | `~/.config` | base for the config directory |
| `AGENT_CONFIG_DIR` | `$XDG_CONFIG_HOME/agent.sh` | config, prompts, plugins, `auth.json` |
| `AGENT_CONFIG` | `$AGENT_CONFIG_DIR/config.json` | user config file |
| `AGENT_SYSTEM_CONFIG` | `/etc/agent.sh/config.json` | system config file |
| `AGENT_PLUGINS` | — | colon-separated plugin files/dirs; `none` loads none |
| `PROMPT_DIR` | — | first prompt directory searched |
| `NIX_STORE_DIR` | `/nix/store` | where `need` looks for builds |

#### Workspace and approval

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORKSPACE` | git toplevel or `$PWD` | the directory the agent may work in |
| `OUTSIDE` | `ask` | `ask`, `allow`, `deny` for paths outside it |
| `ALLOW_PATHS` | empty | colon-separated extra directories that need no question |
| `ASK_CMDS` | `sudo su doas pkexec dd mkfs fdisk parted shutdown reboot poweroff halt systemctl nixos-rebuild crontab chown mount umount` | programs that always need approval (empty = none) |

#### Sandbox (Landlock)

| Variable | Default | Meaning |
| --- | --- | --- |
| `SANDBOX` | `auto` | `auto` = use it where it works, `on` = refuse to run commands without it, `off` = none |
| `SANDBOX_NET` | `1` | `0` also removes network access (needs Linux 6.7+) |
| `SANDBOX_READ` | — | colon-separated paths commands may read as well |
| `SANDBOX_WRITE` | — | colon-separated paths commands may write as well |

A value other than those above stops agent.sh with exit code 2. An explorer
inherits the parent's helper (`AGENT_SANDBOX_BIN`), so the rules are the same
inside one.

#### Prompt line

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROMPT_PATH_MAX` | `32` | width of the directory in the prompt |
| `PROMPT_GIT` | `1` | 1 = show the git branch |
| `PROMPT_MODEL` | `0` | 1 = show the model |
| `PROMPT_CONTEXT` | `1` | 1 = show history size against the compaction threshold |

A non-numeric value for a `PROMPT_*` variable falls back to its default.

#### Copilot internals

Normally leave these alone: `COPILOT_API_URL`
(`https://api.githubcopilot.com/responses`), `COPILOT_TOKEN_URL`
(`https://api.github.com/copilot_internal/v2/token`), `COPILOT_LOGIN_URL`
(`https://github.com`), `COPILOT_EDITOR` (`vscode/1.99.3`), `COPILOT_PLUGIN`
(`copilot-chat/0.26.7`). `AGENT_SUB` and `AGENT_SUB_NAME` are set by the
parent for explorers and are not user settings.

### Validation

All of these stop with exit status 2 and `agent.sh: …`:

- `SUB_MAX`, `SUB_TIMEOUT`, `SUB_MAX_STEPS`, `MAX_STEPS` must be whole numbers.
- `AUTO`, `AUTO_COMPACT`, `SHOW_REASONING`, `PROJECT_DOC`, `SUBAGENTS`, `WEB`
  must be 0 or 1.
- `CONTEXT` must be a non-negative whole number.
- `CMD_TIMEOUT` must be a whole number of seconds.
- `WEB_TIMEOUT`, `READ_LINES`, `MAX_OUT`, `COMPACT_AT`, `TIMEOUT`,
  `AGENT_HISTORY_MAX` must be greater than 0.
- `OUTSIDE` must be `ask`, `allow` or `deny`; `MODE` must be `build` or `plan`;
  `SANDBOX` must be `auto`, `on` or `off` and `SANDBOX_NET` must be 0 or 1.
- `reasoning` must be `minimal`, `low`, `medium`, `high` or empty; `thinking`
  must be `on`, `off` or empty; `temperature` must be 0–2.
- An endpoint URL must be `https://`, `localhost`, `127.0.0.1` or `[::1]`
  (otherwise a warning; `OUTSIDE` is unrelated).

If `COMPACT_AT` is empty it becomes `CONTEXT*2` when `CONTEXT > 0`, else
`100000`, and it follows later `/context` changes. If `CONTEXT > 0` and
`COMPACT_AT >= CONTEXT*4`, a warning says the threshold reaches the context
window. `SUB_MAX` below 1 is raised to 1.

---

## 4. Providers and models

### Built-in providers

| Name | Kind | Default endpoint | Default model | Default reasoning |
| --- | --- | --- | --- | --- |
| `opencode` (alias `opencode-go`) | Responses | `https://opencode.ai/zen/go/v1/responses` | `deepseek-v4.1-flash` | `low` |
| `copilot` (alias `github-copilot`) | Copilot | `https://api.githubcopilot.com/responses` | `gpt-4.1` | server |
| `openai` | Responses | `https://api.openai.com/v1/responses` | `gpt-4.1-mini` | server |
| `openrouter` | Responses | `https://openrouter.ai/api/v1/responses` | `openai/gpt-4.1-mini` | server |
| `ollama` | local | `http://localhost:11434/v1/responses` | `qwen2.5-coder:7b` | server |

Any other name must appear under `providers` in a config file (or be added by a
plugin); otherwise:

```
unknown provider "X"; add it under "providers" in ~/.config/agent.sh/config.json
with a "url" (/provider list shows the others)
```

### Endpoints must speak the Responses API

A custom URL may end in `/responses` or `/chat/completions`
(`/chat/completions` is rewritten to `/responses`); trailing slashes are
stripped. Anything else is refused:

```
the url of provider "X" must end in /responses: URL
```

### Where the key comes from

For an ordinary provider, in order:

1. `AGENT_API_KEY`, if set (source `env AGENT_API_KEY`).
2. `ENVKEY_<NAME>`, i.e. `OPENAI_API_KEY` for `openai`
   (source `env OPENAI_API_KEY`).
3. `providers.NAME.api_key` in a config file (source `config providers.NAME`).
4. The plugin's `P_KEY`, for built-in providers only (source `plugin`).
5. The top-level `api_key` (source `config`), when the top-level settings are
   for this provider.
6. `OPENCODE_API_KEY` for a custom provider (legacy fallback).
7. For a `local` provider: none.

If none applies, the error lists the ways to set one. A key from one provider
is never sent to another.

For Copilot the order is: `AGENT_API_KEY` (source `env AGENT_API_KEY`), then a
saved token from `COPILOT_GITHUB_TOKEN` (source `env COPILOT_GITHUB_TOKEN`),
then `$CONFIG_DIR/auth.json` (`.copilot.oauth_token`), then the token of the
Copilot plugin for Vim/Neovim (`$XDG_CONFIG_HOME/github-copilot/apps.json` or
`hosts.json`). If there is none:

```
not signed in to GitHub Copilot: run agent.sh --login copilot (or /login copilot)
```

### Signing in to Copilot

```sh
agent.sh --login copilot
```

This prints a code and opens GitHub's device flow. The OAuth token is written
to `$CONFIG_DIR/auth.json` (directory 0700, file 0600); `--login` then exits.
In the REPL, `/login copilot` signs in and switches to Copilot. The OAuth token
is exchanged for a short-lived session token at `COPILOT_TOKEN_URL`; that
session is refreshed before an explorer starts (`SUB_TIMEOUT+60`).

### Switching at runtime

```
/provider              # current provider, model, endpoint and key source
/provider info         # the same
/provider list         # every provider and whether it is ready
/provider use NAME [MODEL]
```

`/provider list` marks the current provider and shows `ready, model X` or
`not ready: <reason>`. `/provider use` clears the cached model list, warns if
the endpoint is not `https`/`localhost`/`127.0.0.1`/`[::1]`, and keeps the
chosen name and model for this run (and in the session file).

```
/model                 # model, reasoning, thinking, temperature, context, endpoint
/model list            # models the endpoint offers (chat models only)
/model use 3           # by number
/model use gpt-4.1     # by name
/model set reasoning medium
/model set temperature 0.1
/model set context 128000
/model set compact_at 200000
```

`/model list` fetches `<endpoint minus /responses>/models` and keeps entries
whose `.capabilities.type` is `chat`. `set_model` accepts the keys `model`,
`reasoning`, `thinking`, `temperature`, `context`, `compact_at` and the aliases
`temp` → `temperature`, `effort` → `reasoning`; `default` resets `reasoning`,
`thinking`, `temperature`, `context` (unknown) and `compact_at` (follow the
context). The reasoning settings are also sent per request; reasoning content
some endpoints pack into the model name is stripped.

### API errors

A failed request is retried up to four times on 408, 429 and 5xx, then the
message is surfaced as `API error: …` (with `reply_note` explaining the common
cases) and the turn fails. `TIMEOUT` is the number of seconds of silence
tolerated (`--speed-limit 1 --speed-time TIMEOUT`).

---

## 5. Modes: build and plan

| | build (default) | plan |
| --- | --- | --- |
| runs read-only commands | yes | yes |
| runs other commands | yes | no |
| `edit`/`write` | yes | not offered |
| `explore` | yes | yes |
| system prompt | `SYSTEM.md` | `PLAN.md` + `SYSTEM.md` |

Switch with `-p`/`--plan`, `-b`/`--build` (the last one on the command line
wins), `MODE=plan`, or `/plan` / `/build` in the REPL. A sub-agent is always in
plan mode.

The switch keeps the conversation: only the system prompt is replaced in the
first message, so everything read while planning stays in the history. In the
REPL both commands also take a prompt, `/plan <text>` and `/build <text>`: the
mode is switched and `<text>` is sent in the same step, so one line both leaves
plan mode and starts the work. Without a text, a switch that changes nothing
just says "Already in plan mode." / "Already in build mode.". Going from plan
to build this way — or with a bare `/build` followed by your next message —
prefixes that prompt with:

```
(Switched from plan mode to build mode: carry out the plan above. What you read
while planning is still in this conversation; read a file again only to get the
exact text for an edit, or if it may have changed since.)
```

so the model starts editing instead of re-reading the project. The note is
only added when there is a conversation to carry out (not in a brand-new
session), it is prepended to the *next* user message, and it is not added when
switching to plan mode.

### What plan mode allows

A command is split into simple commands at `;`, `|`, `&`, `(`, `)`, backticks
and newlines; each must pass `plan_simple_ok` and `plan_git_ok`. Plan mode
refuses:

- anything longer than 4000 characters;
- redirections other than `>/dev/null` and `2>&1`;
- command substitution `` `…` ``, `$(…)`, process substitution `<(…)`;
- subshells, brace expansion, `$'…'`, `$"…"`, unbalanced quotes.

Allowed programs:

```
ls cat head tail wc grep egrep fgrep rg find file stat pwd echo printf
cut tr diff comm cmp jq basename dirname readlink realpath du df which
type uname date id ps seq nl od strings paste join expand unexpand fold
tac rev sort tree md5sum sha1sum sha256sum sha512sum cksum test true false
[ [[ ]] : cd fd fdfind fzf ast-grep bat batcat
```

With per-program refusals:

- `find`: `-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`, `-fprint*`, `-fls`
- `sort`, `tree`: `-o`, `--output`, `--compress-program`, `--co*`
- `file`: `-C`, `--comp*`
- `date`: `-s`, `--s*`
- `rg`: `--pre*`, `--hostname-bin*`
- `fd`: `-x`, `-X`, `--exec`
- `fzf`: needs `--filter`; refuses `--bind`, `--preview`, `--listen`,
  `--with-shell`, `--history`, `--execute`, `--become`
- `ast-grep`: refuses `new`, `-U`/`--update-all`, `-i`/`--interactive`
- `bat`: refuses `--pager`, `--paging=always`

Git is allowed through a dedicated check. Refused: `-c`, `--config-env`,
`--output`, `-O`, `--op*`, `--ext-diff`, `--exec*`, `--upload-pack`. Allowed
subcommands: `status`, `diff`, `log`, `show`, `blame`, `ls-files`, `ls-tree`,
`rev-parse`, `grep`, `cat-file`, `show-ref`, `shortlog`, `describe`,
`for-each-ref`; `branch` and `tag` only in listing form (`-l`, `--list`,
`--contains`, `--merged`, `--points-at`, …; `-a`/`-r`/`-v`/`--all` for `tag`
only); `remote` with no argument, `-v`, `--verbose`, `show`, `get-url`;
`config` with `-l`, `--list`, `--get`, `--get-all`, `--get-regexp`,
`--get-urlmatch`; `stash list`/`show`; `reflog` (none or `show`);
`worktree`/`submodule` `list`/`status`/`summary`.

When plan mode refuses a command the model is told:

```
Plan mode: command not run. Only read-only inspection commands are allowed here
```

with `; /build leaves plan mode.` for the main agent (`.` for a sub-agent).
The file tools answer "Plan mode: file not changed. Only reading is allowed
here".

---

## 6. Tools

The tool list is built per run. `bash`, `read` always; `web_search` and
`web_fetch` when `WEB=1`; `explore` when `SUBAGENTS=1`; `edit`, `write` and
`todo` only for the main agent (a sub-agent gets neither file writing nor the
todo list); plus every tool a plugin registers.

| Tool | Arguments | Notes |
| --- | --- | --- |
| `bash` | `command` | one command per call, fresh shell, no stdin |
| `read` | `path`, `offset`, `limit` | line numbers, no directories |
| `edit` | `path`, `old`, `new`, `replace_all` | exact string replacement |
| `write` | `path`, `content` | whole file |
| `todo` | `items[]` of `text`, `status` | the model's plan for the session |
| `web_search` | `query`, `count` (1–10, default 5) | Brave, Tavily, SearXNG or DuckDuckGo |
| `web_fetch` | `url` | http/https only |
| `explore` | `task` | read-only sub-agent |

### bash

Every call runs in a **fresh, non-interactive bash** from `$START_DIR` (the
directory you started in, not the last `cd`). There is no stdin, no job
control and no state carried over between calls; `cd` does not persist and
background output must be redirected to a file. The model is told this in the
system prompt and to stop processes by PID, never with `pkill bash`,
`killall` or `kill -1`.

Before running, the command is checked:

- **workspace**: paths outside the workspace must be approved (see
  [Approval](#13-approval-and-the-workspace));
- **dangerous**: programs in `ASK_CMDS`, a forced push, `git reset --hard`,
  `git clean -f`, or `curl`/`wget … | sh` need approval;
- **self-signalling**: `pkill`/`killall` that would match `sh`/`agent`, or
  `kill … -1`, is refused:
  "Not run: this would signal processes by a name that matches the agent
  itself (or every process you own) … kill it by PID instead."

Then it asks `Run it? [y/N/a=always, or say why not]` unless `AUTO=1` or the
question was already answered "always".

It runs with the user's original umask, in its own process group (`setsid`,
else `set -m`), under `timeout -k 5 CMD_TIMEOUT` when `timeout` is available,
and inside the [sandbox](#sandbox) when it is on, with its own `TMPDIR`.
Output is streamed and kept to `MAX_OUT` bytes, keeping the head and the tail
with `...[N bytes truncated]...` in between; a non-zero exit code is appended.
Ctrl-C stops the process group. A removed start directory is recreated, or the
command is refused ("Not run: the working directory … no longer exists").

### read

Prints up to `READ_LINES` (400) lines with `%6d\t` line numbers. `offset`
starts later; `limit` overrides the default. Directories are refused with
"List it with bash: ls -la"; binaries show "(N bytes); its content is not
shown"; empty files "(path is empty)"; past the end "(path has only N lines)";
a partial read ends with "[lines a-b of total; read on with offset N+1]".
Reading inside the workspace needs no approval; reading outside goes through
the same gate as `bash`. When the [sandbox](#sandbox) is on, the file is read
through it: a file outside the paths it allows answers "the sandbox does not
allow read <path>", like a command would.

### edit and write

`write` replaces the whole file, creating directories as needed, keeping the
permissions of an existing file. `edit` replaces `old` with `new` exactly once
unless `replace_all` is true. Both show a diff first: green `+` lines for new
content (a new file previews its first 20 lines), then ask `Write it?` or
`Apply it?` unless `AUTO=1`. Outside the workspace the path question comes
first. With the [sandbox](#sandbox) on, the file is read and written through
it, so a path outside the paths it allows answers "the sandbox does not allow
write <path>" instead of the change being made.

`edit` refuses, with an explanation the model can act on:

- a missing file ("Use write to create a file");
- a binary file;
- empty `old`, or `old` equal to `new` ("nothing to change");
- `old` not found ("It must match the file exactly … Read the lines again and
  copy them without the line numbers");
- more than one match without `replace_all`.

Results are `Wrote path (N lines).`, `Edited path.` or
`Edited path: N replacements.`.

### todo

The model keeps a plan as a list of up to 50 items with a `status` of
`pending`, `in_progress` or `done`. The list is printed as it changes
(`todo (D of N done)`), stored in the session, survives compaction, and is
shown by `/todo`; `/todo clear` empties it. Text is capped at 300 characters
and control characters are stripped. A sub-agent has no todo list.

### web_search and web_fetch

`web_search` asks `Search for it?` and uses the first configured backend:

1. **Brave** — `BRAVE_API_KEY` (header `X-Subscription-Token`), `BRAVE_URL`.
2. **Tavily** — `TAVILY_API_KEY` (bearer), `TAVILY_URL`, POST
   `{query, max_results}`.
3. **SearXNG** — `SEARXNG_URL`, `GET /search?q=…&format=json`.
4. **DuckDuckGo** — the HTML page at `DDG_URL`, no key, but it may refuse
   automated requests.

Results print as numbered title, URL and snippet. With no results:
"No results from <backend> for: <query>", plus the backend error and, for
DuckDuckGo, "The keyless search may have refused the request; the user can set
BRAVE_API_KEY, TAVILY_API_KEY or SEARXNG_URL."

`web_fetch` accepts only `http`/`https`, asks `Fetch it?`, and runs
`curl -sSL --max-time WEB_TIMEOUT --max-filesize 5000000 --proto '=http,https'
--proto-redir '=http,https' -A agent.sh/<version>`. HTML becomes text through
`w3m`, else `lynx`, else an `awk` filter. Non-text content is reported as
"is not text (ctype, N bytes); not shown."; a non-2xx response is prefixed
with `[HTTP code]`.

Both tools exist only when `WEB=1`; `WEB=0` removes them entirely.

### Sandbox

On Linux with Landlock (5.13 and later) the tools run inside a kernel
sandbox, and `bash`, `read`, `edit` and `write` all go through it:

- **writes** are allowed in the workspace, the starting directory when it is
  outside the workspace, `$TMPDIR` (a private `sandbox` directory inside the
  agent's scratch directory, not the whole of it), `~/.cache`, `/dev` and what
  `SANDBOX_WRITE` adds;
- **reads** are allowed of the system (`/usr`, `/bin`, `/nix`, `/etc`, `/opt`,
  `/run`, `/var`, `/proc`, `/sys`, …), the workspace and the tool directories
  in the home directory (`.local/bin`, `.cargo`, `.rustup`, `go`, `.nvm`,
  `.pyenv`, `.rbenv`, `.bun`, `.deno`, `.sdkman`, `.gitconfig`,
  `.config/git`), plus what `SANDBOX_READ` adds — not the rest of `$HOME`;
- **network** is TCP connect and bind, unless `SANDBOX_NET=0`;
- with Landlock 6 the command also cannot signal processes outside the
  sandbox (the agent) or reach their abstract unix sockets.

The helper is a small C program embedded in the script
(`landlock-run [-r PATH]… [-w PATH]… [-n] -- COMMAND`). It is compiled once
with `cc`, `gcc` or `clang` into `$(dirname SESSION_DIR)/bin/`, named after a
checksum of its source, and reused; `landlock-run -V` prints the kernel's
Landlock ABI. Without a compiler, or on a kernel without Landlock, the sandbox
is reported as unavailable and commands run as before (`SANDBOX=auto`, the
default). `SANDBOX=on` refuses to start without it, `SANDBOX=off` turns it off.

Whatever the sandbox allows is open to every command: a script in the
workspace can still write elsewhere in the workspace. A refused file shows up
as "Permission denied", which the file tools translate to "the sandbox does
not allow read/write <path>"; the system prompt tells the model not to try to
get around it. A workspace that is `$HOME` (or `/`) gets a warning on stderr,
since it would leave the whole home directory writable. `/about` shows the
state; an explorer inherits the parent's helper and rules.

### Limits

- `MAX_OUT` (20000) bytes of each tool result reach the model.
- `MAX_STEPS` (0 = none) caps tool rounds per turn; at the limit the model is
  told it has used all its steps and gets one final request without tools.
- `CMD_TIMEOUT` (600) caps one command; `TIMEOUT` (300) caps network silence;
  `WEB_TIMEOUT` (30) caps a fetch or search.

### CLI hints

When `rg`, `fd`/`fdfind`, `fzf`, `ast-grep` or `tree` are installed, the system
prompt tells the model to prefer them over `grep -r` and `find`, including
that `rg` and `fd` skip ignored and hidden files, that `fzf` needs `--filter`
here, and that `bat` is not suggested. `CLI_HINTS=0` removes the paragraph.

---

## 7. Sub-agents (explorers)

The `explore` tool starts a **read-only** sub-agent with a task description.
Explorers search the project in parallel; they cannot edit, write, ask
questions, use the web or save sessions. They have `bash` (plan-mode rules
apply), `read`, and no todo list.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SUBAGENTS` | 1 | 0 removes the `explore` tool |
| `SUB_MAX` | 4 | at most this many run at once; the rest queue |
| `SUB_TIMEOUT` | 300 | seconds one explorer may take |
| `SUB_MAX_STEPS` | 25 | tool rounds one explorer may use |

Mechanics:

- The task is written to `$SUB_DIR/N.task`; the prompt is `Task: <task>`.
- The explorer is `timeout -k 5 SUB_TIMEOUT "$SELF" -- "Task: …"` with
  `AGENT_SUB=1`, `AGENT_SUB_NAME="explorer N"`, a copied `AGENT_API_KEY`, and
  the model/provider/URL/reasoning/temperature/`OUTSIDE`/`WORKSPACE`/
  `ALLOW_PATHS`/`ASK_CMDS`/`READ_LINES`/`COMPACT_AT` settings exported. Its
  `SESSION_DIR` is under the scratch directory, `AGENT_HISTFILE=/dev/null`,
  `SHOW_REASONING=0`.
- Starting one prints `[explorer N] <task>`; finishing prints
  `[explorer N] done in Ns` and the (clipped) report, which becomes the tool
  result.
- A failure is reported as "The explorer failed: it was stopped after Ns
  (SUB_TIMEOUT)", "it returned no report", or "exit code N: …" with what it
  printed before that. Ctrl-C stops all explorers ("Explorer stopped: the user
  interrupted.").
- Explorers never ask for approval — the parent's gate applies to the commands
  they run, and with no terminal the question is refused.

Because every explorer is a full `agent.sh` process, `SUB_*`, `MODEL`,
`PROVIDER`, `URL`, `REASONING`, `THINKING`, `TEMPERATURE`, `MAX_OUT`,
`TIMEOUT`, `CMD_TIMEOUT`, `PROJECT_DOC`, `AUTO_COMPACT`, `COMPACT_AT`,
`OUTSIDE`, `WORKSPACE`, `ALLOW_PATHS`, `ASK_CMDS` and `READ_LINES` are exported
into it; `PROMPT_DIR` is passed down when set. A sub-agent is always in plan
mode, whatever the parent's mode.

---

## 8. Prompts

### Where prompts are found

For `SYSTEM.md`, `COMPACTION.md`, `PLAN.md` and `EXPLORE.md`, the search path
is:

1. `$PROMPT_DIR`, when set;
2. `$CONFIG_DIR/prompts`;
3. `<install dir>/pro.mpts`.

The first non-blank file wins; a missing or blank file keeps the built-in.
`/about` shows where each prompt came from.

On the first run the bundled prompts are copied into
`$CONFIG_DIR/prompts` as `NAME.md.example`; rename one to `NAME.md` to use it.
`name.example` files are never read.

### Placeholders

Inside any prompt and any prompt command:

| Placeholder | Replaced with |
| --- | --- |
| `{{cwd}}` | the current directory |
| `{{workspace}}` | the workspace |
| `{{os}}` | `uname -sm` |
| `{{date}}` | today (`YYYY-MM-DD`) |

### AGENTS.md

If `./AGENTS.md` exists, is not blank and `PROJECT_DOC=1`, up to 20000 bytes
are appended to the system prompt as "Project instructions from
<dir>/AGENTS.md:". NUL bytes are stripped. `/about` shows whether one was
used. `PROJECT_DOC=0` turns it off.

### Prompt commands

A file `commands/NAME.md` in a prompt directory becomes `/NAME` in the REPL.
The bundled ones are:

| Command | Purpose |
| --- | --- |
| `/commit` | write a commit message and commit |
| `/debug` | find the cause of a bug |
| `/docs` | document something |
| `/explain` | explain code |
| `/fix` | fix a problem |
| `/init` | write an `AGENTS.md` for the project |
| `/refactor` | restructure code without changing behaviour |
| `/review` | review a change |
| `/security` | look for security problems |
| `/test` | write or run tests |

The first line may be an HTML comment, which becomes the description shown by
`/help`. Text after the command name replaces `{{args}}`, or is appended as a
new paragraph when the file has no `{{args}}`. `/NAME` prints `(/NAME: <file>)`
and the rendered prompt becomes your message. An unknown `/NAME` is
"Unknown command /NAME (try /help)." and fails the turn for one-shot runs.

A plugin command of the same name takes precedence; see [Plugins](#9-plugins).

### The built-in prompts

The system prompt explains that the agent is a coding agent with a fresh
non-interactive bash per command, no persistent `cd`, no stdin, background
output to a file, the `explore` tool, and that processes must be stopped by PID
and never with `pkill bash`, `killall` or `kill -1`; it asks for concise
answers. The plan prompt adds "plan only, read-only commands, finish with a
step-by-step plan", and asks the model to read the files it plans to change
itself (explorers report back but leave the files out of the conversation) and
to name the functions and lines, so the plan can be carried out without looking
at the code again. The explorer prompt is the plan prompt plus the reporting
instructions. The compaction prompt asks for a summary that preserves what
matters to continue the work.

`apply_mode` rewrites the system message to match the mode: build uses
`SYSTEM.md`; plan uses `PLAN.md` + `SYSTEM.md`; a sub-agent uses
`EXPLORE.md` + `SYSTEM.md`.

---

## 9. Plugins

A plugin is a bash file sourced at startup (before the config is loaded). It
can add commands, tools, providers and hooks.

### Loading

- `$CONFIG_DIR/plugins/*.sh` is always loaded, in name order.
- `AGENT_PLUGINS` adds more: a colon-separated list of files or directories
  (a directory expands to its `*.sh`). `AGENT_PLUGINS=none` loads nothing.
  A missing path prints "AGENT_PLUGINS: X does not exist".
- Files are sourced with `set +u`; a failure is reported but not fatal.
- A world-writable file or directory, or one owned by another user, is refused.

### Declaring things

```sh
agent_command NAME "help text"          # /NAME in the REPL
agent_tool NAME "description" '{"type":"object","properties":{…}}' [ro]
agent_provider NAME                     # adds a provider
agent_hook EVENT FUNCTION               # start turn_start turn_end exit tool_call
```

Names are lower-case letters, digits and `_`. A name that collides with a
built-in (commands `help about model provider login compact context sessions
resume reset auto plan build exit quit plugins todo tmp`, tools `bash read
write edit web_search web_fetch explore todo`, providers `opencode
opencode-go copilot github-copilot openai openrouter ollama`) or with another
plugin is refused with a warning.

`agent_tool`'s schema must be a JSON object; the default is an empty object
schema. `ro` marks a tool read-only, which lets it run in plan mode and
without a confirmation.

### Commands

`agent_command stamp "…"` plus a function `cmd_stamp`:

```sh
cmd_stamp() { AGENT_PROMPT="The date is $(date +%F). $*"; }
```

Setting `AGENT_PROMPT` makes its value the next input; the arguments after the
command name are `$*`. Returning without setting it sends nothing. If the
function is missing: "agent.sh: /NAME: the plugin did not define cmd_NAME".

### Tools

A tool declared with `agent_tool` calls `tool_NAME "$args"`: the arguments
arrive as one JSON string in `$1`. Unless the tool is `ro`, plan mode refuses it
("Plan mode: NAME is not read-only, so it was not run.") and it asks `Run it?`
unless `AUTO=1`. Output is clipped to `MAX_OUT` with `[output truncated]...`,
and a non-zero exit adds `[exit code N]`. A missing function yields "Error: the
plugin did not define tool_NAME."

### Providers

`agent_provider work` plus `provider_work`, which sets `P_URL`, `P_MODEL`,
`P_REASONING`, `P_KIND` (`plain`, `local` or `copilot`) and `P_KEY`. Optional
`provider_work_headers` adds request headers, and `provider_work_prepare` runs
before a request (a non-zero return fails with `PLUGIN_ERR`). A plugin provider
is selected like any other: `PROVIDER=work`, `/provider use work`.

### Hooks

| Event | When | Arguments |
| --- | --- | --- |
| `start` | after startup, before the REPL | — |
| `turn_start` | before a user message is sent | the input |
| `turn_end` | after the turn | `TURN_OK`: 1 when the turn worked, 0 when it failed |
| `exit` | on the way out | — |
| `tool_call` | before each tool runs | tool name and arguments |

A `tool_call` hook that exits non-zero blocks the call; whatever it printed on
stdout is the reason shown to the model ("Not run: a plugin blocked this call:
…"). Hooks are not run in sub-agents. A missing hook function prints
"hook EVENT: no function NAME".

### Inspecting

`/plugins` lists the loaded files, then `commands`, `tools`, `providers` and
`hooks`. With nothing loaded: "No plugins. Put *.sh files in
<config dir>/plugins (see the README)."

---

## 10. Command-line reference

```
agent.sh [-y] [-p | -b] [-i] [-c | -r SESSION_ID] [-h] [-V] [prompt...]
agent.sh -l [all]
agent.sh --login [copilot]
```

Long options are handled before `getopts ":ycr:lhVpbi"`:

| Option | Effect |
| --- | --- |
| `--help` | print the help (the comment block at the top of the script) and exit 0 |
| `--version` | print `agent.sh 0.6.1` and exit 0 |
| `--plan` | same as `-p` |
| `--build` | same as `-b` |
| `--new` | start a new session, keeping the old one as a backup |
| `--login [copilot\|github-copilot]` | sign in to Copilot and exit |
| `--` | everything after it is the prompt |

| Short | Effect |
| --- | --- |
| `-y` | `AUTO=1`: run tools without asking (the workspace and dangerous-command questions still appear) |
| `-p` | plan mode |
| `-b` | build mode (the default) |
| `-i` | with a prompt, stay in the REPL afterwards |
| `-c` | continue the most recent session in this directory |
| `-r ID` | resume a session by full id or unique prefix |
| `-l [all]` | list saved sessions for this directory (or all) and exit 0 |
| `-h` | help |
| `-V` | version |

Notes:

- The pre-scan stops at the first word that is not an option: everything from
  there on is the prompt. Use `--` before a prompt that starts with `-`.
- `-r` needs an id: `agent.sh: -r needs a session id`, exit 2.
- An option that needs an argument but has none: `-X needs an argument`,
  exit 2.
- An unknown short option: `unknown option -X (try -h)`, exit 2. An unknown
  long option gives `unknown option --X (try -h)`, also exit 2.
- `--login` with another provider: `cannot log in to 'X' (only copilot)`,
  exit 2.
- `SUB=1` (set by the parent) forces plan mode, `AUTO=1`, no sub-agents, no
  web, `MAX_STEPS=SUB_MAX_STEPS`, and requires a task.
- A prompt without `-i` is **one-shot**: it is answered, the session is saved
  and the process exits. If the turn failed, the exit status is 1, so one-shot
  runs are usable in scripts. An unknown `/command` and a refused approval are
  failures.
- `-l` and `--login` exit before the REPL.

---

## 11. The REPL

The prompt line shows mode, directory, git branch, (optionally) the model,
history size against the compaction threshold, `auto`, `tmp` and the session
id (see [section 15](#15-the-prompt-line-about-model-and-context)).

Line editing is readline: history is read from `AGENT_HISTFILE` (trimmed to
`AGENT_HISTORY_MAX` lines, mode 0600) and each line is appended there. Ctrl-C
draws a fresh prompt and abandons the line; Ctrl-D or `/exit` quits.

Both kinds of multi-line input work:

- **pasting**: a pasted block arrives as several lines, not only its first
  one. Bracketed paste is turned off so that the lines after the first stay
  in the terminal and are read after readline is done; they are echoed dimmed
  and go to the model as one message. A message is sent when the block ends,
  not line by line.
- **continuing**: a line that ends in `\` leaves the backslash out and shows a
  `... ` prompt for the next line; the lines are joined with a newline, so a
  shell command can be written over several lines, and a message can too.

Piped input is not affected: one line is one message, so a script feeding
`/plan\ntext` gets exactly that.

Inside a temporary session (`/tmp on`), `/reset`, `/resume` and `/resume ID`
are refused with "In a temporary session: /tmp off first."

| Input | Effect |
| --- | --- |
| `/help` | the command list, including plugin and prompt commands |
| `/about` | the session card: version, author, config, provider, model, endpoint, key source, session, sessions dir, auto, mode, compaction, prompts, project doc, workspace, tools, CLI, plugins, search, explorers, runtime |
| `/model`, `/model info` | model, reasoning, thinking, temperature, context, endpoint |
| `/model list` | the endpoint's chat models, current one marked |
| `/model use <n\|id>` | switch model for this run |
| `/model set <key> <value>` | change one setting (`model`, `reasoning`, `thinking`, `temperature`, `context`, `compact_at`) |
| `/provider`, `/provider info` | provider, model, endpoint, key source |
| `/provider list` | providers and readiness |
| `/provider use <name> [model]` | switch provider |
| `/login`, `/login copilot`, `/login github-copilot` | sign in and switch to Copilot |
| `/context`, `/context info` | the window and the compaction threshold |
| `/context <tokens\|default>` | set the window |
| `/context compact <bytes\|default>` | set the compaction threshold |
| `/compact` | summarize the history now |
| `/tmp`, `/tmp on`, `/tmp off` | temporary-session state, fork, return |
| `/sessions`, `/sessions all` | list sessions (this workspace or all) |
| `/resume`, `/resume <id\|prefix>` | list, or switch to a session |
| `/reset` | start a new session; if this workspace has a saved one, it asks first and keeps it as a backup |
| `/auto` | toggle running commands without confirmation |
| `/plan [text]`, `/build [text]` | switch mode, sending `text` as the next prompt (`/build` also tells the model to carry out the plan) |
| `/todo`, `/todo clear` | show or clear the todo list |
| `/plugins` | loaded plugins and what they added |
| `/exit`, `/quit` | quit (Ctrl-D too) |
| `/NAME [text]` | a prompt command or plugin command |

Exact spellings matter: `/model  set` (two spaces) falls through to the
`/model *` usage line, `/sessions  all` is not `/sessions all`, and only the
first word after `/tmp` / `/resume` is used (`/tmp on extra` is `/tmp on`).
Anything not matching a listed command is either a plugin command, a prompt
command, or a message to the model — so "/usr/bin is broken" is a message, not
a command; only `/name` (a letter, then letters, digits, `_`, `-`) can match a
prompt command, and an unknown one is an error rather than a message.

Usage/error lines worth knowing:

- `/provider use` with three words: "Usage: /provider use <name> [model]"
- `/model use` with two arguments: "Usage: /model use <number or name>"
- `/login X`: "Usage: /login copilot"
- `/todo *`: "Usage: /todo [clear]"
- `/model set` with bad input: "Usage: /model set X <value>", "Reasoning must
  be minimal, low, medium, high or default.", "Thinking must be on, off or
  default.", "Temperature must be a number from 0 to 2, or default.",
  "Context must be a number of tokens, or default (unknown).", "compact_at
  must be a number of bytes, or default."

If the workspace has a saved session and you did not pass `-c`/`-r`, the first
message triggers the [session choice](#12-sessions) instead of being sent.

---

## 12. Sessions

A session is one JSON file under `$SESSION_DIR`
(`~/.local/state/agent.sh/sessions/`), named after its id. It holds the
conversation, the todo list and the settings (provider, model, api, reasoning,
thinking, temperature, context, compaction threshold) — never the URL or the
API key.

### One session per workspace

Each run works on at most one session **for the current workspace**
(`$PWD`, compared literally). The newest session whose `cwd` is this directory
is its session; older ones are kept in `$SESSION_DIR/backup/`. Starting fresh
in a workspace that already has a session does not silently stack a second one:

- `-c` / `-r` continue or switch;
- `--new` starts a new one and moves the old one to the backup (silently);
- a one-shot prompt this time is *not saved* and says so:
  "(this workspace has a saved session: this run is not saved; -c continues
  it, --new replaces it)";
- an interactive run asks at the first message:
  "This workspace has a saved session XXXXXXXX (N user messages, last: …)"
  then `[r]esume it, start [n]ew (it is kept as a backup), or [c]ancel?`.
  `n` moves the old session to the backup ("the previous session XXXXXXXX is
  kept as a backup: /resume XXXXXXXX"), `r` loads it, `c` drops your prompt
  ("Cancelled; your prompt was not sent (Up brings it back).").
- with no terminal to ask on, the run is not saved ("no terminal to ask on:
  this run is not saved; -c resumes it").

`--new` skips the question entirely. Sessions saved by older versions (several
per workspace) are all moved to the backup, and the next start-over drops the
older ones: the backup holds one session per workspace.

### Picking a session

| How | Result |
| --- | --- |
| `-c` | the newest session for this directory, else "no saved session for <dir>", exit 1 |
| `-r ID` | a session by full id, else by unique prefix, in sessions and backups |
| `-r ID` in the REPL via `/resume ID` | the same |
| `-l [all]` | a listing and exit |

`/resume` with no argument lists the sessions and prints "Usage: /resume <id
or unique prefix>". A bad id says "Invalid session id 'X'.", an unknown one
"No saved session matches 'X'.", an ambiguous prefix "'X' matches N sessions;
type more of the id."

Switching to a session of **another workspace** opens it as a temporary
session: its messages and todos are loaded, but nothing is saved ("Opened
session X of ~/path as a temporary session (not saved; /tmp off comes back).").
Switch back with `/tmp off`. A session of the same workspace that lives in the
backup is swapped in place: the current one is saved, the backup moved in via
`.restore`, and the old current one becomes the backup.

### Listing

`/sessions` and `-l` list at most 20, newest first, for this workspace, under
"Saved sessions in ~/path:"; `/sessions all` and `-l all` list every
workspace under "Saved sessions, all workspaces:". Each line is:

```
* 2026-01-31 14:02  3f2a91bc-…-…                    12 msgs  first 50 chars of the first message
```

(the id is padded to 36 columns; the last field is the first 50 characters of
the first user message, `-` when there is none)

The `*` marks the current session; a yellow `backup` tag marks one in the
backup directory; `all` adds the working directory. Empty: "No saved sessions
in <dir> (/sessions all lists every workspace)." or "No saved sessions."

### Restoring

Loading prints "Resumed session <id> (N user messages)" and the last assistant
message, dimmed and truncated to 300 characters. Settings are restored, but
values set in the environment for this run win. If the saved provider no
longer resolves, it says "cannot go back to provider … staying on X". The
restored settings are printed as `settings: model …, reasoning …, compacts at
N bytes`. A dangling tool call (the session ended mid-call) is repaired with
"Not run: the session ended first.".

Sessions are written after each turn and after `/todo` changes, atomically
(`<file>.$$.tmp` then `mv`). A compacted history leaves a `.json.bak` copy of
the previous transcript.

### Temporary sessions

`/tmp on` forks the current session: a copy of the messages and todos that is
**never saved**. Everything works as usual; `/tmp off` returns to the main
session and drops the fork ("the temporary one (N new messages) was dropped").
Bare `/tmp` says which one you are in. Temporary sessions also arise from
`/resume` of another workspace's session. While one is open, `/reset` and
`/resume` are refused. On exit: "(the temporary session was dropped)".

A run is not saved when: it is a sub-agent, it is a one-shot run in a
workspace that already has a session, the session question was cancelled, or
there was no terminal to ask on.

### The session file

```json
{
  "id": "3f2a…",
  "cwd": "/home/me/project",
  "settings": {
    "provider": "opencode",
    "model": "deepseek-v4.1-flash",
    "api": "responses",
    "reasoning": "low",
    "thinking": "",
    "temperature": "",
    "context": 128000,
    "compact_at": 256000
  },
  "todos": [],
  "messages": [ … ]
}
```

`compact_at` is `"auto"` when it follows the context. Files are created with
mode 0600 in a directory with mode 0700.

---

## 13. Approval and the workspace

### The workspace

The workspace is the git repository containing the starting directory, or the
starting directory itself when it is not in a repository; `WORKSPACE` overrides
it. A workspace naming a symlink into the start directory is refused. The
agent starts each command in the starting directory, not the workspace root.

Paths inside the workspace need no approval. Paths outside it do, every time,
**also under `-y`**. The following are always free:

```
/usr /bin /sbin /lib /lib32 /lib64 /libexec /opt /etc /nix/store
/run/current-system /proc /sys /dev /tmp /var/tmp /private/tmp
```

plus `$TMPDIR` and every absolute entry of `ALLOW_PATHS` (colon-separated).
`$CONFIG_DIR` is never free, so plugin and config paths are always questioned.
The start directory and the workspace itself are free. This is the approval
layer; on Linux the [sandbox](#sandbox) is a second, independent layer that
applies whatever the answer is.

`OUTSIDE` decides what happens:

| `OUTSIDE` | Effect |
| --- | --- |
| `ask` (default) | ask before touching a path outside |
| `allow` | never ask about paths |
| `deny` | refuse, "Leaving the workspace is not allowed in this session; work inside it." |

### Dangerous commands

A command that starts with a program in `ASK_CMDS` needs approval even under
`-y`. The default list is `sudo su doas pkexec dd mkfs fdisk parted shutdown
reboot poweroff halt systemctl nixos-rebuild crontab chown mount umount`;
`ASK_CMDS=""` empties it. Wrappers (`env`, `command`, `exec`, `nohup`, `time`,
`nice`, `ionice`, `stdbuf`, `timeout`, `xargs`, `watch`) are looked through, so
`timeout 5 sudo …` is still caught. Also dangerous:

- `git push --force*`, `--mirror`, `--delete`, `-f`;
- `git reset --hard`, `git clean -f`;
- `curl`/`wget` piped into `sh`/`bash`/`zsh`/`dash`.

The check reads the command text: `sudo` inside a quoted string that is never
executed still counts, and a script that calls `sudo` internally does not.

### The question

When a command needs approval:

```
Needs your approval: it reaches outside the workspace (/home/me): /etc/hosts
Allow it? [y/N/a=always this session, or say why not]
```

- `y` allows this one;
- `n` or Enter refuses;
- `a` allows this and everything after it in the session: "Tools may now leave
  the workspace without asking." and/or "Dangerous commands now run without
  this question.";
- anything else is passed to the model as the reason: "The user did not allow
  it and said: …". That text is how you steer it elsewhere without retyping.

The question is asked on `/dev/tty`, so it works while output streams. With no
terminal (a pipe, a sub-agent, a cron job):

> It needs the user's approval and there is no terminal to ask on. Find another
> way, or tell the user what you need and why.

`AUTO=1` (`-y`, `/auto`) auto-approves the ordinary `Run it?`/`Write it?`
questions but not the workspace or dangerous-command gate.

This is a seat belt, not a sandbox: it inspects the command text and the paths
it can see. On Linux the [sandbox](#sandbox) is what actually confines the
command; where it is unavailable, run the agent in a directory and with an
account you are willing to give it.

---

## 14. Compaction

The conversation is summarized when it grows past `COMPACT_AT` bytes
(`AUTO_COMPACT=1`, the default) or when you type `/compact`. `COMPACT_AT`
defaults to `CONTEXT*2` (≈ half the window at 4 bytes per token) when `CONTEXT`
is set, else 100000 bytes, and it follows `/context` changes unless you set it
explicitly.

The summary request runs without tools. Everything except the newest exchange
becomes the summary the next turn starts from:

> Summary of the conversation so far (everything before it was compacted to
> save context): …

The latest exchange is kept verbatim when it is small enough (at most half the
threshold) and there is more than one message; otherwise everything is folded.
The todo list is appended to the request so the plan survives. The old
transcript is copied to `<session>.json.bak`. Mid-turn compaction says
"(history is N bytes; compacting it first)"; a failure says "(compaction failed;
carrying on)" and the turn continues. `/compact` on an empty history says
"Nothing to compact yet."; Ctrl-C during it says "Compaction interrupted; the
history is unchanged."; an empty summary says "Could not compact: …". On
success: "(compacted N messages into a summary, kept the last M; X -> Y
bytes)".

`/about` and `/context` show the threshold; `AUTO_COMPACT=0` disables the
automatic kind but keeps `/compact` working.

---

## 15. The prompt line, /about, /model and /context

### The prompt line

```
build ~/work/agent.sh main* gpt-4.1 12k/50k auto tmp 3f2a91bc $
```

| Part | Meaning |
| --- | --- |
| `build` / `plan` | the mode (green / magenta) |
| the path | the current directory, shortened from the left to `PROMPT_PATH_MAX` (32) with `...` |
| the git badge | branch, `*` when there are uncommitted changes, `detached`, nothing outside a repo (`PROMPT_GIT=0` hides it) |
| the model | only with `PROMPT_MODEL=1` |
| `12k/50k` | history bytes against `COMPACT_AT` (just `12k` when the automatic compaction is off or the threshold is below it; `PROMPT_CONTEXT=0` hides it) |
| `auto` | commands run without asking |
| `tmp` | a temporary session |
| `3f2a91bc` | the first 8 characters of the session id |

### /about

The `/about` card is printed for every fresh session and on demand. It shows:

- `agent.sh 0.6.1 — a coding agent in bash`, author, release date, MIT;
- the config file (and whether it was loaded);
- provider, model, parameters (reasoning/thinking/temperature or "server
  default"), endpoint, and the key source ("set (env OPENAI_API_KEY)");
- the session id, the sessions directory;
- `auto` ("ask first" / "run without asking"), mode, compaction ("automatic
  above N bytes" or "only with /compact");
- prompts (`SYSTEM.md from …`), the project doc, the workspace (and the
  outside-workspace policy);
- the tool names, the CLI line, the plugins, the search backend, the explorer
  settings, the sandbox (its Landlock ABI, or why it is off) and `bash
  <version>, jq <version>, curl <version>`.

It is the fastest way to see why a setting is not doing what you expect.

### /model and /context

`/model` prints provider, model, reasoning/thinking/temperature ("server
default" when unset), the context ("N tokens (compacts at M bytes)" or
"unknown"), the endpoint, and:

> Change one with: /model set <model|reasoning|thinking|temperature|context|compact_at> <value>

`/context` prints the window and the threshold ("(follows the context)" when
automatic) and:

> Change: /context <tokens|default>   /context compact <bytes|default>

Both keep their values in the session.

---

## 16. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `agent.sh: 'jq' is required but was not found.` | install `jq`/`curl`, or install Nix so `need` can fetch them |
| `unknown provider "X"` | the name is not built in: add it under `providers` with a `url` |
| `the url of provider "X" must end in /responses` | the endpoint does not speak the Responses API |
| `not signed in to GitHub Copilot` | `agent.sh --login copilot` |
| `no saved session for <dir>` | no session was saved for this directory yet: run without `-c` |
| "this run is not saved" | a one-shot run in a workspace that already has a session: use `-c`, `--new` or `-i` |
| "no terminal to ask on" | a tool needed approval with no `/dev/tty`: run interactively, use `-y`, `OUTSIDE=allow` or `ALLOW_PATHS` |
| The model keeps using `grep -r` | `CLI_HINTS=0` is set, or `rg`/`fd` are not installed |
| Compaction runs too often | raise `COMPACT_AT` or set `CONTEXT` correctly; `AUTO_COMPACT=0` stops it |
| A command stops after 10 minutes | that is `CMD_TIMEOUT=600`; raise it or set 0 |
| A reply stops for no reason | `TIMEOUT=300` of network silence; raise it |
| Tool results look cut | `MAX_OUT=20000`; raise it |
| Endless turn | set `MAX_STEPS` (e.g. 50) to bound a turn |
| Edits ask twice | outside-workspace approval plus the `Write it?` question; `OUTSIDE=allow` and `-y` change that |
| History/line editing behaves oddly | check `AGENT_HISTFILE` and `AGENT_HISTORY_MAX` |
| Warning about `api_key` permissions | `chmod 600 ~/.config/agent.sh/config.json` |
| Warning that `COMPACT_AT` reaches the window | raise `CONTEXT` or lower `COMPACT_AT` |
| An explorer failed | raise `SUB_TIMEOUT`/`SUB_MAX_STEPS`, or run the search yourself |
| "the sandbox does not allow …" | the path is outside what the sandbox allows: add it to `SANDBOX_READ`/`SANDBOX_WRITE` |
| The sandbox is unavailable | no Landlock kernel (Linux 5.13+) or no `cc`/`gcc`/`clang` to build its helper; `SANDBOX=off` silences it |

Debugging tips: `/about` for the effective configuration; `/provider list` for
key readiness; `/plugins` for what loaded; `bash -x ./agent.sh` to trace the
script itself. Everything the script reports goes to stderr.

---

## 17. Development

```sh
nix develop          # bashInteractive, curl, jq, fzf, ripgrep, ast-grep, fd, shellcheck
nix flake check      # build + shellcheck
shellcheck agent.sh
```

The script is kept `shellcheck`-clean; do not silence a finding without a
comment explaining why. The help text printed by `-h` is the comment block at
the top of the script (the comment block above `set -euo pipefail`), so edit
it there. The version lives in
`VERSION=` and is read by the Nix package; bump it together with
`RELEASED`. The flake exposes `packages.<system>.{agent-sh,default}`,
`apps.default`, `overlays.default`, `nixosModules.default` and the dev shell.

Tests are manual: the one-shot exit status, the approval refusals, the
plan-mode allow-list and a real streaming request against each provider are
the things worth checking after a change.

---

## 18. License

MIT. See [LICENSE](LICENSE). Author: fb87. Release history:
[CHANGELOG.md](CHANGELOG.md) and `RELEASE-vX.Y.Z.md`.
