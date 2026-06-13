{
  description = "Docker Services Backup (DSB) script";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Read base version from the script
        scriptText = builtins.readFile ./src/dsb.sh;
        scriptLines = pkgs.lib.splitString "\n" scriptText;
        isVerLine = pkgs.lib.hasPrefix "readonly DSB_VERSION=";
        versionLine = pkgs.lib.findFirst isVerLine "" scriptLines;
        versionMatch = builtins.match ".*\"([^\"]+)\".*" versionLine;
        baseVer = builtins.head versionMatch;

        # Dynamically calculate version using base version + flake shortRev
        version = "${baseVer}-${self.shortRev or "dirty"}";
      in
      {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "dsb";
          inherit version;
          src = ./src;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          buildPhase = ''
            # Inject dynamic flake version into the bash script
            substituteInPlace dsb.sh \
              --replace-fail \
              "DSB_VERSION=\"${baseVer}\"" \
              "DSB_VERSION=\"${version}\""
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp dsb.sh $out/bin/dsb
            chmod +x $out/bin/dsb

            # Wrap script to ensure its dependencies are available in PATH
            wrapProgram $out/bin/dsb \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.restic
                  pkgs.docker
                ]
              }
          '';

          meta = with pkgs.lib; {
            description = "Docker Services Backup (DSB) script";
            homepage = "https://github.com/MOIS3Y/dsb";
            license = licenses.mit;
            platforms = platforms.linux ++ platforms.darwin;
            mainProgram = "dsb";
          };
        };

        apps.default =
          flake-utils.lib.mkApp {
            drv = self.packages.${system}.default;
            name = "dsb";
          }
          // {
            meta = self.packages.${system}.default.meta;
          };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Tools for development and linting
            shellcheck
            shfmt
            bats

            # Runtime dependencies for local testing
            restic
            docker
          ];
        };
      }
    );
}
