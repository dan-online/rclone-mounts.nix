{
  description = "NixOS module for system-level rclone mounts with per-mount ownership, rc credentials and hang recovery";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosModules.default = ./module.nix;

      checks.x86_64-linux.mounts = pkgs.testers.runNixOSTest {
        imports = [ ./tests/mounts.nix ];
        defaults.imports = [ self.nixosModules.default ];
      };

      formatter.x86_64-linux = pkgs.nixfmt-tree;
    };
}
