# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  bundled prompts into it; an existing directory or file is left untouched.

### Changed

- Prompt overrides are now looked up per file in `$PROMPT_DIR` (if set), then
  `$XDG_CONFIG_HOME/agent.sh/prompts`, then `<install dir>/pro.mpts`, and
  finally the built-in prompt. The first non-blank file wins.
- `PROMPT_DIR` no longer defaults to `./pro.mpts`; the script looks next to
  itself, so prompts are found when it is run from another directory or from
  a Nix profile. Set `PROMPT_DIR` to keep pointing at a specific tree.

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

[Unreleased]: https://github.com/fb87/agent.sh/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/fb87/agent.sh/releases/tag/v0.2.0
[0.1.0]: https://github.com/fb87/agent.sh/releases/tag/v0.1.0
