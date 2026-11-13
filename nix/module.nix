self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.agent-sh;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.programs.agent-sh = {
    enable = lib.mkEnableOption "the agent.sh coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.default;
      defaultText = lib.literalExpression "agent.sh.packages.\${system}.default";
      description = "The agent.sh package to install.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        provider = "opencode";
        model = "deepseek-v4.1-flash";
      };
      description = ''
        System-wide settings written to {file}`/etc/agent.sh/config.json`.
        Do not put an API key here: that file is world-readable. Put it in
        {file}`~/.config/agent.sh/config.json` (mode 0600) or in the
        `AGENT_API_KEY` environment variable instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."agent.sh/config.json" = lib.mkIf (cfg.settings != { }) {
      text = builtins.toJSON cfg.settings;
    };
  };
}
