{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; config.allowUnfree = true; }));
    in {
      packages = forAllSystems (pkgs: {
        default = pkgs.buildEnv {
          name = "cluster-tools";
          paths = with pkgs; [
            talosctl
            talhelper
            kubectl
            sops
            age
            claude-code
          ];
        };
      });
    };
}
