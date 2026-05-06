{
  description = "mob - parallel coding task manager for jj repositories";

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
    zmxPkg = zmx.packages.${system}.default;

    # Deps bundled into the package wrapper (standard tools, no user customization)
    bundledDeps = [
      pkgs.skim
      pkgs.bubblewrap
    ];

    mob = pkgs.stdenvNoCC.mkDerivation {
      pname = "mob";
      version = "0.1.0";
      src = ./.;

      nativeBuildInputs = [pkgs.makeBinaryWrapper];

      installPhase = ''
        mkdir -p $out/libexec/mob $out/bin

        # Install both nu files side-by-side so `source sandbox.nu` works
        cp mob.nu sandbox.nu $out/libexec/mob/

        # Wrapper that invokes nushell with --no-config-file on the entrypoint
        makeBinaryWrapper ${pkgs.lib.getExe pkgs.nushell} $out/bin/mob \
          --add-flags "--no-config-file" \
          --add-flags "$out/libexec/mob/mob.nu" \
          --prefix PATH : "${pkgs.lib.makeBinPath bundledDeps}"
      '';

      meta.mainProgram = "mob";
    };
  in {
    packages.${system}.default = mob;

    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.nushell
        pkgs.skim
        pkgs.bubblewrap
        zmxPkg
      ];
    };
  };
}
