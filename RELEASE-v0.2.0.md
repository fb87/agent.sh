# agent.sh v0.2.0

Two new ways to steer the agent: plan before you build, and change the model's
settings without leaving the REPL. Still one bash file, `jq` and `curl`.

```sh
./agent.sh --plan          # inspect only, no edits
./agent.sh "fix the tests" # one-shot, build mode
```

## Highlights

- **Plan mode.** Start with `-p` / `--plan`, `MODE=plan` or `/plan` in the
  REPL: the agent may only run read-only inspection commands, and edits or
  other state-changing commands are refused. `/build` (or `--build`) returns
  to the default build mode.
- **`/model`.** `/model` prints the model name, reasoning effort, thinking and
  temperature. `/model set <model|reasoning|thinking|temperature> <value>`
  changes one for the current run; `MODEL`, `REASONING`, `THINKING` and
  `TEMPERATURE` do the same from the environment. Defaults leave the request
  unchanged: `low` reasoning, no `thinking` field and no `temperature` field.
- **A plan prompt you own.** `PLAN.md` in `./pro.mpts/` (or `$PROMPT_DIR`)
  joins `SYSTEM.md` and `COMPACTION.md` as an overridable built-in prompt.

Everything from [v0.1.0](RELEASE-v0.1.0.md) is still there: streaming replies
with reasoning, the confirmed bash tool, persistent sessions, `/compact` and
automatic compaction, and `/about`.

## Requirements

`bash`, `jq`, `curl`. Tested on bash 5.x; session prefix matching also works on bash < 4.4.

## Configuration

All optional, all by environment variable:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL` | `deepseek-v4.1-flash` | model to call |
| `REASONING` | `low` | reasoning effort (`""` = omit the field) |
| `THINKING` | unset | `on`/`off` (`""` = server default) |
| `TEMPERATURE` | unset | `0`..`2` (`""` = server default) |
| `URL` | OpenCode Go chat completions | OpenAI-compatible endpoint |
| `AUTO` | `0` | `1` = run commands without asking |
| `MODE` | `build` | `plan` = read-only commands, no edits |
| `MAX_OUT` | `20000` | tool output bytes sent back to the model |
| `AUTO_COMPACT` | `1` | summarize a long history automatically |
| `COMPACT_AT` | `100000` | history bytes that trigger it |
| `TIMEOUT` | `300` | seconds of silence before giving up |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions live |
| `PROMPT_DIR` | `./pro.mpts` | prompt override directory |
| `AGENT_HISTFILE` | `~/.agent_sh_history` | readline history |
| `AGENT_HISTORY_MAX` | `1000` | lines kept in that file |

## Full changelog

See [CHANGELOG.md](CHANGELOG.md#020---2026-11-13).

## License

MIT — see [LICENSE](LICENSE).
