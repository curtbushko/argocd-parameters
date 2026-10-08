{
  description = "Local Argo CD ApplicationSet Helm parameter integration test";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in {
      devShells = nixpkgs.lib.genAttrs systems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.bash pkgs.coreutils pkgs.gnumake pkgs.curl pkgs.jq
              pkgs.yq-go pkgs.kind pkgs.kubectl pkgs.kubernetes-helm
              pkgs.argocd pkgs.docker-client pkgs.direnv pkgs.nix-direnv
              pkgs.shellcheck pkgs.shfmt
            ];
            ARGOCD_VERSION = "v${pkgs.argocd.version}";
          };
        });
    };
}
