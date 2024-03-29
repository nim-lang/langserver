{pkgs ? import <nixpkgs> {}}:
let
  # NimLangServer currently relies on the latest
  # version of Nimble which hasn't been released
  # yet. We'll reference it directly here until
  # a release is available.
  latest-nimble = pkgs.stdenv.mkDerivation rec {
    pname = "latest-nimble";
    version = "0.15.0-dev";
    strictDeps = true;
    gitRev = "b2f9acc0af176fda37d6c7dd782d6165b6188784";

    src = pkgs.fetchFromGitHub {
      owner = "nim-lang";
      repo = "nimble";
      rev = gitRev;
      hash = "sha256-7vYDyyRQoOjLftIolDFZ1dg8CTu670kEsVyqIzMgDiU=";
    };

    depsBuildBuild = [ pkgs.nim ];
    buildInputs = [ pkgs.openssl ]
      ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.Security;

    nimFlags = [ "-d:release -d:git_revision_override=${gitRev}" ];

    buildPhase = ''
      runHook preBuild
      HOME=$NIX_BUILD_TOP nim c $nimFlags src/nimble
      runHook postBuild
    '';

    installPhase = ''
      runHook preBuild
      install -Dt $out/bin src/nimble
      runHook postBuild
    '';

    meta = with pkgs.lib; {
      description = "Package manager for the Nim programming language";
      homepage = "https://github.com/nim-lang/nimble";
      license = licenses.bsd3;
      maintainers = with maintainers; [ ehmry ];
      mainProgram = "nimble";
    };
  };
in
with pkgs;
  mkShell {
    buildInputs =
      [
        figlet
        git
        gnumake
        latest-nimble
        nim
      ];

    shellHook = ''
      figlet "Nim Lang Server"
    '';
  }
