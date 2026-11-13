# agent.sh

A coding agent in a single bash file. One script, `jq` and `curl`; it talks to
an OpenAI-compatible chat-completions endpoint and can inspect, edit and run
things in the current directory.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
./agent.sh --plan          # inspect only, no edits
```

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
needs `bash`, `jq` and `curl`.

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
`TEMPERATURE`. Other knobs are still environment-only: `AUTO`, `MODE`,
`MAX_OUT`, `AUTO_COMPACT`, `COMPACT_AT`, `TIMEOUT`, `SESSION_DIR`,
`AGENT_HISTFILE`, `AGENT_HISTORY_MAX`, `PROMPT_DIR` and the config path
overrides `AGENT_CONFIG`, `AGENT_CONFIG_DIR`, `AGENT_SYSTEM_CONFIG`.
Run `agent.sh -h` for the rest.

## Prompts

`SYSTEM.md`, `COMPACTION.md` and `PLAN.md` are looked up per file, and the
first non-blank one wins:

1. `$PROMPT_DIR` (if set),
2. `$XDG_CONFIG_HOME/agent.sh/prompts/`,
3. `<install dir>/pro.mpts/`,
4. the built-in prompt.

So you can override just `SYSTEM.md` and keep the bundled `PLAN.md`. A blank
file falls through to the next location. `{{cwd}}` in a prompt is replaced by
the working directory. Package installs ship `pro.mpts` beside the real
script; check `/about` to see which file each prompt came from.

On the first run, `agent.sh` creates `$XDG_CONFIG_HOME/agent.sh/prompts/` and
copies the bundled prompts into it, so they are ready to edit. The directory
is only created once; existing files are never overwritten.

## Usage

| Command | Purpose |
| --- | --- |
| `/about` | version, config, provider/model, endpoint, prompts, sessions |
| `/model` | show model settings; `/model set <key> <value>` changes one |
| `/compact` | summarize the history (also automatic past `COMPACT_AT`) |
| `/sessions [all]` | list saved sessions |
| `/resume ID` | switch to a session by id or unique prefix |
| `/reset` | start a new session |
| `/auto` | toggle command confirmation |
| `/plan` / `/build` | switch between read-only and editing modes |
| `/exit` | quit (or Ctrl-D) |

Sessions are JSON files under `~/.local/state/agent.sh/sessions`; `-c`
continues the latest in the current directory, `-r ID` resumes one, `-l [all]`
lists them. A fresh session (no `-c`/`-r`) starts with the `/about` card.

## Development

```sh
nix develop        # bash, jq, curl, shellcheck
nix build          # ./result/bin/agent.sh
nix flake check
```

## License

MIT — see [LICENSE](LICENSE). Changes are in [CHANGELOG.md](CHANGELOG.md).
