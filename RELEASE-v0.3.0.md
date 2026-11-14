# agent.sh v0.3.0

This release packages agent.sh for Nix, lets the model explore a project in
parallel, and stops it from wandering out of the workspace. Still one bash
file, `jq` and `curl`.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
./agent.sh --plan          # inspect only, no edits
```

## Highlights

- **Nix flake and NixOS module.** `nix run github:fb87/agent.sh` runs it
  straight from the flake; `nix profile install` puts it on `PATH` with
  `bash`, `jq` and `curl`. The flake also provides a dev shell, a formatter
  and an overlay, and `nixosModules.default` installs the package
  (`programs.agent-sh.enable`) and can write `/etc/agent.sh/config.json`
  from `programs.agent-sh.settings`.
- **JSON configuration.** `provider`, `model`, `url`, `api_key`, `reasoning`,
  `thinking` and `temperature` are read from `/etc/agent.sh/config.json`,
  then `$XDG_CONFIG_HOME/agent.sh/config.json`, then the environment.
  `AGENT_API_KEY` is the primary key variable; `OPENCODE_API_KEY` keeps
  working, and a key in a world-readable config file produces a warning.
- **Prompts you can override one file at a time.** `SYSTEM.md`,
  `COMPACTION.md`, `PLAN.md` and `EXPLORE.md` are looked up in `$PROMPT_DIR`,
  then `~/.config/agent.sh/prompts/`, then beside the script. On first run
  the bundled prompts are copied there as `NAME.md.example`, ready to rename.
  `/about` shows which file each prompt came from.
- **Read-only `explore` sub-agents.** The model can start separate read-only
  agents that search the project in parallel and report back. `SUB_MAX` caps
  how many run at once (4), `SUB_TIMEOUT` how long one may take (300 s), and
  `SUBAGENTS=0` removes the tool.
- **`AGENTS.md` support.** A project's `AGENTS.md` joins the system prompt
  automatically (up to 20 KB); `PROJECT_DOC=0` turns this off.
- **Approval for risky commands.** A command that names a path outside the
  workspace (the git repository, or the starting directory) needs approval
  every time, also under `-y`, as do programs in `ASK_CMDS` (`sudo`, `dd`,
  `reboot`, ...), a forced push, a hard reset, `git clean -f` and a download
  piped into a shell. `OUTSIDE=allow`/`deny` and `ALLOW_PATHS` adjust this,
  and the prompt offers "always this session". It reads the command text
  only: a seat belt, not a sandbox.
- **Sturdier execution.** `MAX_STEPS` caps the tool rounds of a turn,
  `CMD_TIMEOUT` stops a command that runs too long, and commands run in their
  own process group so Ctrl-C or exit stops what they started. A missing
  `jq` or `curl` is taken from the Nix store when possible. State, history
  and scratch files are private (`umask 077`), and one-shot runs exit
  non-zero when the turn fails.

Everything from [v0.2.0](RELEASE-v0.2.0.md) is still there: plan and build
modes, `/model`, streaming replies with reasoning, session resume and
compaction, prompt overrides and `/about`.

## Requirements

`bash`, `jq`, `curl`. Tested on bash 5.x; session prefix matching also works
on bash < 4.4.

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
| `AUTO_COMPACT` | `1` | summarize a long history automatically |
| `COMPACT_AT` | `100000` | history bytes that trigger it |
| `TIMEOUT` | `300` | seconds of silence before giving up |
| `CMD_TIMEOUT` | `600` | seconds one command may run (`0` = no cap) |
| `MAX_STEPS` | `0` | tool rounds per turn (`0` = no limit) |
| `SUBAGENTS` | `1` | `0` removes the `explore` tool |
| `SUB_MAX` | `4` | explorers running at the same time |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions live |
| `PROMPT_DIR` | unset | explicit prompt directory |

## Full changelog

See [CHANGELOG.md](CHANGELOG.md#030---2026-11-14).

## License

MIT — see [LICENSE](LICENSE).
