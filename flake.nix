{
  description = "Multi-threaded HTTP server (C) with zig build/test layer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.clangStdenv.mkDerivation {
          pname = "httpserver";
          version = "1.0.0";
          src = self;
          # Makefile hardcodes CC=clang and the rubric flags; just build it.
          buildPhase = "make";
          installPhase = ''
            mkdir -p $out/bin
            install -m755 httpserver $out/bin/httpserver
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/httpserver";
        };
      });

      devShells = forAllSystems (pkgs: {
        # Everything the repo's gates need:
        #   make + clang        — build (rubric flags)
        #   clang-tools         — clang-format for `make format`
        #   zig 0.15            — build.zig + ztest runner
        #   python3 + toml      — olivertwist/sherlock/watson harness
        #   netstat (2 sources) — test_scripts/utils.sh port polling
        #   valgrind            — M4 leak gate
        #   actionlint          — CI workflow linting
        default = pkgs.mkShell {
          packages = with pkgs; [
            gnumake
            clang
            clang-tools
            zig
            (python3.withPackages (ps: [ ps.toml ]))
            unixtools.netstat
            nettools
            valgrind
            actionlint
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        build = self.packages.${pkgs.system}.default;
      });
    };
}
