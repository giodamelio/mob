{
  description = "mob - project flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    zmx.url = "github:neurosnap/zmx";
  };

  outputs = {
    self,
    nixpkgs,
    zmx,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.nushell
        pkgs.skim
        zmx.packages.${system}.default
      ];
    };
  };
}
