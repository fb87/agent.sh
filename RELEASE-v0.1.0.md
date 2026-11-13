# agent.sh v0.1.0

A coding agent in a single bash file. One script, `jq` and `curl` — no runtime,
no dependencies to install, no project to bootstrap.

```sh
./agent.sh                 # REPL
./agent.sh "fix the tests" # one-shot
```

## Highlights

- **Single file.** `agent.sh` is the whole program. Copy it into `~/bin` and
  you have an agent.
- **Streaming replies** including the model's reasoning, shown dimmed.
- **A bash tool** the model calls, with per-command confirmation by default
  (`-y` to skip) and output capped before it is fed back.
- **Sessions that persist.** Saved as JSON per directory; continue the latest
  with `-c`, resume by id or unique prefix with `-r`, list with `-l`.
- **It stays inside the context window.** `/compact` folds the history into a
  summary on demand, and does it automatically past `COMPACT_AT` bytes,
  keeping the previous transcript as `<id>.json.bak`.
- **Prompts you own.** Drop `SYSTEM.md` / `COMPACTION.md` into `./pro.mpts/`
  to replace the built-in prompts; `{{cwd}}` is expanded.
- **`/about` and `-V`** print the version and the whole environment it is
  running in: model, endpoint, session dir, compaction threshold, which
  prompts are in use, bash/jq/curl versions.

## Requirements

`bash`, `jq`, `curl`. Tested on bash 5.x; session prefix matching also works on bash < 4.4.

## Configuration

All optional, all by environment variable:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL` | `deepseek-v4.1-flash` | model to call |
| `URL` | OpenCode Go chat completions | OpenAI-compatible endpoint |
| `AUTO` | `0` | `1` = run commands without asking |
| `MAX_OUT` | `20000` | tool output bytes sent back to the model |
| `AUTO_COMPACT` | `1` | summarize a long history automatically |
| `COMPACT_AT` | `100000` | history bytes that trigger it |
| `TIMEOUT` | `300` | seconds of silence before giving up |
| `SESSION_DIR` | `~/.local/state/agent.sh/sessions` | where sessions live |
| `PROMPT_DIR` | `./pro.mpts` | prompt override directory |
| `AGENT_HISTFILE` | `~/.agent_sh_history` | readline history |
| `AGENT_HISTORY_MAX` | `1000` | lines kept in that file |

## Full changelog

See [CHANGELOG.md](CHANGELOG.md#010---2026-11-13).

## License

MIT — see [LICENSE](LICENSE).
