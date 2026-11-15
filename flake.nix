{
  description = "agent.sh — a coding agent in a single bash file";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs, ... }: rec {
          agent-sh = pkgs.callPackage ./nix/package.nix { };
          default = agent-sh;
        }
      );

      apps = forAllSystems (
        { system, ... }: {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/agent.sh";
          };
        }
      );

      overlays.default = final: prev: {
        agent-sh = final.callPackage ./nix/package.nix { };
      };

      nixosModules.default = import ./nix/module.nix self;
      nixosModules.agent-sh = self.nixosModules.default;

      devShells = forAllSystems (
        { pkgs, ... }: {
          default = pkgs.mkShell {
            packages = with pkgs; [
              bashInteractive
              curl
              jq
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt);

      checks = forAllSystems (
        { pkgs, ... }: {
          shellcheck = pkgs.runCommandLocal "agent-sh-shellcheck" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            shellcheck ${./agent.sh}
            touch $out
          '';
        }
      );
    };
}
