# agent.sh v0.6.2

This release puts a real fence around the agent. On Linux with Landlock,
whatever the model runs — commands and the `read`, `edit` and `write` tools
alike — can write only in the workspace, gets a private temporary directory,
and no longer sees the rest of your home directory, so the API key, the config
and the session files stay out of reach. The REPL also takes pasted text as
the lines you pasted and a line ending in `\` continues on the next one. Still
one bash file, `jq` and `curl`.

```sh
./agent.sh                     # REPL
SANDBOX=on ./agent.sh          # refuse to run anything unsandboxed
./agent.sh "fix the tests"     # one-shot
```

## Highlights

- **A Landlock sandbox.** Commands may write only in the workspace, a private
  `$TMPDIR` and `~/.cache`; they may read the system (including `/nix`), the
  workspace and the usual tool directories (`.local/bin`, `.cargo`,
  `.rustup`, `go`, `.nvm`, …), and nothing else of `$HOME`. The key is not in
  their environment anyway, and now `~/.config/agent.sh` and the sessions are
  not readable either. A refused path shows up as "Permission denied" from the
  kernel, and the system prompt tells the model not to try to get around it.
- **The file tools obey it too.** `read`, `edit` and `write` do their file
  access through the same rules, so an edit outside them answers "the sandbox
  does not allow write <path>" instead of silently going around the fence. A
  file inside is read once, and the diff is still shown before the write.
- **Settings that fit the way you work.** `SANDBOX=auto` (the default) uses it
  wherever it works and says so in `/about`; `SANDBOX=on` refuses to run
  commands without it; `SANDBOX=off` turns it off. `SANDBOX_NET=0` takes TCP
  connect and bind away as well (Linux 6.7+). `SANDBOX_READ` and
  `SANDBOX_WRITE` add colon-separated paths.
- **No compiler, no sandbox, no problem.** The helper is a 130-line C program
  embedded in the script, built once with `cc`, `gcc` or `clang` into the
  agent's state directory, named after a checksum of its source and reused
  after that. Where a compiler or the kernel is missing, `/about` says why and
  agent.sh works as before; only `SANDBOX=on` makes that an error.
- **Explorers are sandboxed the same way.** A sub-agent inherits the parent's
  helper and rules, so plan mode and the sandbox line up instead of one
  depending on the other.
- **Pasting and continuation.** A pasted block arrives as the lines it
  contains instead of only the first one, echoed dimmed, and sent as one
  message. A line ending in `\` drops the backslash and continues at a `... `
  prompt, so a long prompt or a shell command can be typed over several lines.
  Piped input is unchanged: one line is one message.

## Fixed

- The `/reset` question spans two lines again without tripping shellcheck, so
  `nix flake check` passes.

Everything from [v0.6.1](RELEASE-v0.6.1.md) is still there: temporary
sessions, one session per workspace, `/plan TEXT` and `/build TEXT`, the
Responses API only, the `todo` tool, plugins, the built-in providers and
GitHub Copilot sign-in, prompt commands, plan and build modes, `explore`
sub-agents, `AGENTS.md`, sessions and compaction, the Nix flake and module,
and JSON configuration. The [user manual](MANUAL.md) documents all of it.

## Upgrading

Nothing to change: no flag, setting or session format moved, and the sandbox
is on by default wherever it works. Two things to know:

- The first run builds the helper, which takes a moment and needs a C
  compiler. After that it is a file in `~/.local/state/agent.sh/bin`.
- If a workflow reads or writes outside the workspace without a setting to
  say so, it is now refused. Add the path with `SANDBOX_WRITE=/path` (or
  `SANDBOX_READ=/path`), or set `SANDBOX=off` to get the old behaviour back.

Check `/about`: the `sandbox` line names the Landlock ABI in use, or why it is
not.

## Requirements

`bash`, `jq`, `curl`. The sandbox needs Linux 5.13 or later (6.7 for
`SANDBOX_NET=0`) and, once, a C compiler; without either, agent.sh says so and
runs commands unsandboxed. Web search works out of the box through
DuckDuckGo's HTML page; an API key or `SEARXNG_URL` makes it more reliable.

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
| `SANDBOX` | `auto` | `on` = refuse to run commands without it, `off` = none |
| `SANDBOX_NET` | `1` | `0` also removes network access (Linux 6.7+) |
| `SANDBOX_READ`, `SANDBOX_WRITE` | unset | extra paths commands may read or write |
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

See [CHANGELOG.md](CHANGELOG.md#062---2026-11-26).

## License

MIT — see [LICENSE](LICENSE).
