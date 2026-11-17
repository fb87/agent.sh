# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-11-17

### Added

- The `todo` tool and `/todo` command: the model keeps a plan for a task
  with several steps as a list of pending, in progress and done items. The
  list is shown as it changes, saved with the session and carried through
  compaction; `/todo` (or `/todo clear`) shows or clears it.

### Changed

- Every request goes to the Responses API; it is now the only endpoint
  agent.sh speaks. The built-in providers point at `/responses`, `url` has
  to end in `/responses` (a URL ending in `/chat/completions` is moved
  over), and the session file records `api: responses`.

### Removed

- **Breaking:** the `/chat/completions` endpoint. Endpoints that only serve
  it, and models an endpoint offers only there, can no longer be used; point
  `url` at a gateway that translates, or pick a model the endpoint also
  serves at `/responses`. The per-request fallback and the list of models
  that needed `/responses` are gone with it, so `AGENT_RESPONSES_MODELS` is
  now ignored.

## [0.5.0] - 2026-11-17

### Added

- Bundled prompt commands: `/review`, `/security`, `/explain`, `/debug`,
  `/fix`, `/test`, `/refactor`, `/docs`, `/commit` and `/init` (writes an
  `AGENTS.md`). A file of the same name in your own prompt directory
  replaces one.
- Bundled `PLAN.md` and `EXPLORE.md`, so every prompt has a file to copy and
  adjust.
- Plugins: `*.sh` files in `$XDG_CONFIG_HOME/agent.sh/plugins` and in
  `AGENT_PLUGINS` (colon-separated; `none` loads none) are sourced at startup
  as trusted code. They add REPL commands (`agent_command`), tools
  (`agent_tool`, read-only or confirmed before use), providers
  (`agent_provider`, with optional extra headers and a preparation step) and
  hooks (`agent_hook`: `start`, `turn_start`, `turn_end`, `exit`,
  `tool_call`). Built-in names are reserved, plugin commands show up in
  `/help`, and `/plugins` lists the files and what each one added. A file
  that is world-writable or owned by another user is not loaded, and a file
  that fails to load is reported and skipped.
- Built-in providers `copilot` (GitHub Copilot), `openai`, `openrouter` and
  `ollama` next to `opencode`; `PROVIDER` picks one, and the new `providers`
  object in `config.json` sets a model, key or endpoint per provider (and
  adds a provider of your own).
- `agent.sh --login copilot` and `/login copilot`: GitHub's device flow signs
  in and keeps the token in `$XDG_CONFIG_HOME/agent.sh/auth.json` (mode
  `0600`, directory `0700`). `COPILOT_GITHUB_TOKEN`, or the token of the
  Copilot plugin for Vim/Neovim, also works.
- `/provider`, `/provider list` and `/provider use NAME [MODEL]`: show the
  current provider, model, endpoint and where the key comes from, list which
  providers are ready, and switch for this run.
- `/context` shows the context window and the compaction threshold;
  `/context N` sets the window in tokens and `/context compact BYTES` the
  threshold (`default` restores the automatic value). `/model set` accepts
  `context` and `compact_at` too, and a session keeps both.
- A model that refuses `/chat/completions` and accepts `/responses` is
  remembered and used from then on; `AGENT_RESPONSES_MODELS` sets the pairs
  up front, `/about` shows it, and explorers inherit the list.
- When `rg`, `fd`, `fzf`, `ast-grep` or `tree` is installed, the model is
  told to use it instead of `grep -r` and `find` (`CLI_HINTS=0` turns the
  hints off).
- A session now saves the provider, model, reasoning, thinking, temperature,
  context and compaction threshold after each turn, and `-c`/`-r` restore
  them. Keys and URLs are not saved, and values set in the environment for
  this run are kept.

### Changed

- Each provider has its own default model and reasoning effort. The
  top-level `model`, `url`, `api_key` and `reasoning` belong to the provider
  named at startup, so switching never sends one provider's key to another
  endpoint.
- A command that names the config directory always asks for approval, even
  when it is inside the workspace.

### Fixed

- Switching provider drops the reasoning text of the previous model from the
  conversation instead of sending it to an endpoint that did not produce it.
- The Nix package installs `pro.mpts/commands/`.

## [0.4.0] - 2026-11-15

### Added

- File tools: `read` (numbered lines, at most `READ_LINES`), `edit` and
  `write`. Reading inside the workspace needs no approval; edit and write
  show the change and ask, refuse binary files, and create missing
  directories. All three stop at the workspace like commands do.
- Web tools: `web_search` (Brave with `BRAVE_API_KEY`, Tavily with
  `TAVILY_API_KEY` or a SearXNG server with `SEARXNG_URL` when one is set,
  else DuckDuckGo's HTML page) and `web_fetch`, which turns a page into text.
  `WEB=0` removes both, and the keys can also be set in the config file.
- Prompt commands: `commands/NAME.md` in a prompt directory becomes `/NAME`
  in the REPL; the first line may be an HTML comment describing it for
  `/help`, `{{args}}` takes the text typed after the name, and without it
  that text is appended. Prompts may use `{{cwd}}`, `{{workspace}}`, `{{os}}`
  and `{{date}}`.
- `CONTEXT` (tokens) for the model's context window. When it is set,
  `COMPACT_AT` defaults to half of the window, counting 4 bytes per token
  (e.g. `CONTEXT=128000` compacts at 256000 bytes), so compaction no longer
  uses one hardcoded byte threshold for every model. Without `CONTEXT` the
  old `100000`-byte threshold stays; a `COMPACT_AT` past the window produces
  a warning, and `/model` shows the window and the threshold.
- `/model list` and `/model use <number or name>`: the REPL asks the
  endpoint's `/models` (derived from `URL`) for the models it offers, marks
  the current one and switches to another for this run. A number must be in
  the list; a name that is not is sent anyway with a warning, so private or
  alias names keep working. Failures (bad key, no network, no list) are
  reported and leave the current model alone.
- `nix flake check` now runs `shellcheck` on `agent.sh`, so linting (and the
  quoting, `eval` and word-splitting findings behind most script security
  bugs) is part of the check instead of an optional local habit.

### Changed

- A warning is printed when the API endpoint is not `https` and not
  localhost.
- Configuration values are validated strictly: integers and the `0`/`1`
  flags are checked, as are session ids, before they are used.
- Plan mode refuses more repository-changing git options (push and proxy
  options, `--exec*`, upload-pack and sorting options) and no longer treats
  `git ls-remote` as read-only.
- Explorers never ask for approval: a tool call that would need one is
  refused instead.
- Text produced by the model is sanitized before it reaches the terminal,
  and a path is resolved through symlinks before a directory is created.

## [0.3.0] - 2026-11-14

### Added

- Nix flake: `packages.<system>.default` / `apps.default`, an overlay, a dev
  shell, a formatter, and `nixosModules.default`. The module installs the
  package (`programs.agent-sh.enable`) and can write
  `/etc/agent.sh/config.json` from `programs.agent-sh.settings`.
- JSON configuration: `provider`, `model`, `url`, `api_key`, `reasoning`,
  `thinking` and `temperature` are read from `/etc/agent.sh/config.json`,
  then `$XDG_CONFIG_HOME/agent.sh/config.json`, then the environment.
  `provider = "opencode"` (or `opencode-go`) selects the default endpoint.
- `AGENT_API_KEY` is now the primary API key variable; `OPENCODE_API_KEY`
  keeps working. A config file holding an `api_key` that is readable by
  others produces a warning.
- `/about` shows the config path, provider, API-key source and the file each
  prompt came from.
- A fresh session (no `-c`/`-r`) prints the `/about` card as a banner.
- The first run creates `$XDG_CONFIG_HOME/agent.sh/prompts/` and copies the
  bundled prompts into it as `NAME.md.example`, ready to rename when you want
  to override one. The directory is created once; existing files are left
  untouched.
- Read-only `explore` sub-agents: the model can start separate read-only
  `agent.sh` children that inspect the project and report back. Several run in
  parallel (`SUB_MAX`, default 4) and are bounded by `SUB_TIMEOUT` (300) and
  `SUB_MAX_STEPS` (25); `SUBAGENTS=0` removes the tool, and `EXPLORE.md` can
  replace the explorer instructions.
- `AGENTS.md` in the working directory is added to the system prompt (up to
  20 KB) so project instructions apply automatically; `PROJECT_DOC=0` turns
  this off.
- `-b`/`--build` (build mode, the default; the last of `-p`/`-b` wins) and
  `-i` (stay in the REPL after a command-line prompt). A one-shot run now
  exits non-zero when its turn fails.
- `MAX_STEPS` caps the tool rounds of one main-agent turn; at the limit the
  model is asked for a final answer instead of being cut off mid-turn.
- `CMD_TIMEOUT` (600 seconds) stops a command that runs too long when
  `timeout` is available. Commands run in their own process group, so Ctrl-C
  or exit stops what they started, not just the shell.
- A missing `jq` or `curl` is taken from the Nix store when possible; otherwise
  `agent.sh` says what to install and stops.
- Commands that reach outside the workspace now need approval every time, also
  under `-y`. The workspace is the git repository that contains the starting
  directory (else that directory); common read-only system locations and
  anything in `ALLOW_PATHS` are exempt. `OUTSIDE=allow` turns the question off
  and `OUTSIDE=deny` refuses such commands. `WORKSPACE` sets the workspace.
- Dangerous commands likewise need approval every time: a program in
  `ASK_CMDS` in command position (`sudo`, `dd`, `reboot`, ...; `""` empties
  the list), a forced push, a hard reset, `git clean -f`, or a download piped
  into a shell. The prompt offers "always this session" for either kind.
- `/about` shows the workspace and how commands outside it are treated.

### Changed

- The REPL prompt shows the mode, the directory, the git branch (`*` for
  uncommitted changes), the history size against `COMPACT_AT` and `auto`
  when commands run without asking, and only 8 characters of the session
  id. `PROMPT_PATH_MAX`, `PROMPT_GIT`, `PROMPT_MODEL` and
  `PROMPT_CONTEXT` control it; `/about` shows the full id.

- `-y` still runs ordinary commands without asking, but no longer approves a
  command that reaches outside the workspace or looks dangerous; those are
  asked about (or refused with `OUTSIDE=deny`).
- Prompt overrides are now looked up per file in `$PROMPT_DIR` (if set), then
  `$XDG_CONFIG_HOME/agent.sh/prompts`, then `<install dir>/pro.mpts`, and
  finally the built-in prompt. The first non-blank file wins.
- `PROMPT_DIR` no longer defaults to `./pro.mpts`; the script looks next to
  itself, so prompts are found when it is run from another directory or from
  a Nix profile. Set `PROMPT_DIR` to keep pointing at a specific tree.
- The API key is unset from the environment of commands the model runs and
  handed to `curl` in a header file rather than on its command line. State,
  history and scratch files are created private (`umask 077`).
- Generated prompt files use the `NAME.md.example` suffix, so they do not
  shadow the bundled prompt and hide its updates.
- Automatic compaction also runs between tool steps of a long turn. The
  latest exchange is kept verbatim when it is small enough and everything
  before it becomes the summary.
- `/resume` re-applies the current mode and working-directory context, so a
  session saved in the other mode or directory is brought in step.
- Plan-mode command filtering is stricter about quoting, redirections and
  `git` subcommands.

### Fixed

- Scratch files live beside the sessions instead of in `/tmp`, so a command
  that cleans `/tmp` cannot remove them; scratch directories left by a killed
  run are cleaned up on the next start.
- The readline history file is kept at mode `0600`.
- Explorers are stopped when their parent is interrupted or exits, and a
  turn stopped by Ctrl-C no longer reports success in one-shot mode.

## [0.2.0] - 2026-11-13

### Added

- Plan mode (`-p`, `--plan`, `MODE=plan`, REPL `/plan`): the agent may only
  run read-only inspection commands; edits and other state-changing commands
  are refused. `/build` (or `--build`) returns to the default build mode.
- `/model` shows the model name, reasoning effort, thinking and temperature;
  `/model set <model|reasoning|thinking|temperature> <value>` changes one for
  the current run (also `MODEL`, `REASONING`, `THINKING`, `TEMPERATURE` in the
  environment). Defaults keep the request unchanged: `low` reasoning, no
  `thinking` and no `temperature` field.

## [0.1.0] - 2026-11-13

First public release: a single-file coding agent in bash, talking to an
OpenAI-compatible endpoint (OpenCode Go).

### Added

- `agent.sh` — one self-contained bash script with an interactive REPL and a
  one-shot mode (`agent.sh "prompt"`), using `jq` and `curl` only.
- Streaming replies with reasoning output shown dimmed (`SHOW_REASONING`).
- A bash tool the model can call; output is truncated to `MAX_OUT` bytes
  before it goes back to the model.
- Command confirmation by default, `-y`/`AUTO=1` to run without asking;
  skipped with a clear message when there is no tty.
- Sessions saved as JSON per directory under
  `$SESSION_DIR` (`~/.local/state/agent.sh/sessions`):
  `-c` continues the latest, `-r ID` resumes by full id or unique prefix,
  `-l [all]` lists them, and the REPL has `/sessions`, `/resume` and `/reset`.
- `/compact` and automatic compaction (`AUTO_COMPACT`, `COMPACT_AT`): a long
  history is folded into one summary, with the previous transcript kept as
  `<id>.json.bak`.
- Prompt overrides: `SYSTEM.md` and `COMPACTION.md` in `./pro.mpts/`
  (or `$PROMPT_DIR`) replace the built-in prompts; blank or missing files
  fall back, and `{{cwd}}` is expanded. The shipped prompt files spell out the
  tool contract (fresh shell, no stdin, no interactive programs) and ask for a
  dense Goal / Done / Commands / State / Next summary.
- `-V`/`--version` and `/about`, reporting author, release date, license,
  model, endpoint, session directory, auto mode, compaction threshold, which
  prompts are in use, and the bash/jq/curl versions.
- `-h`/`--help` generated from the script header, and `/help` in the REPL.
- Ctrl-C stops the current reply or command without ending the session.
- Configurable `MODEL`, `URL`, `TIMEOUT`, `SESSION_DIR`, `PROMPT_DIR`,
  `AGENT_HISTFILE` and `AGENT_HISTORY_MAX`; the readline history file is
  trimmed to `AGENT_HISTORY_MAX` lines (default 1000).

### Fixed

- Error bodies are unwrapped, so a failed request reports the server's message
  (e.g. `invalid api key`) instead of a nested JSON blob; plain-text proxy
  error pages are handled too.
- A command's exit status is taken from `PIPESTATUS[0]`, so a successful
  command is no longer reported to the model as `[exit code 1]` under
  `pipefail`.
- A session file without a usable `messages` array is refused instead of
  leaving `MESSAGES="null"`, and the system prompt is reinstated if missing.
- A message that cannot be appended no longer kills the script.
- Session prefix resolution no longer needs `nullglob` or `${#array[@]}`,
  so it works on bash < 4.4.
- Sessions are written through a per-process temp file.

### Known limitations

- Only the OpenCode Go chat-completions endpoint is exercised; other
  OpenAI-compatible servers may need `URL` and `MODEL` adjustments.
- Model output is trusted as JSON only as far as the API guarantees it; a
  malformed stream aborts the turn rather than being repaired.

[Unreleased]: https://github.com/fb87/agent.sh/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/fb87/agent.sh/releases/tag/v0.6.0
[0.5.0]: https://github.com/fb87/agent.sh/releases/tag/v0.5.0
[0.4.0]: https://github.com/fb87/agent.sh/releases/tag/v0.4.0
[0.3.0]: https://github.com/fb87/agent.sh/releases/tag/v0.3.0
[0.2.0]: https://github.com/fb87/agent.sh/releases/tag/v0.2.0
[0.1.0]: https://github.com/fb87/agent.sh/releases/tag/v0.1.0
