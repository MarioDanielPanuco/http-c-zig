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
        #   nginx/oha/wrk       — bench/ (nginx baseline + load generators)
        default = pkgs.mkShell {
          packages = with pkgs; [
            gnumake
            clang
            clang-tools
            # Pinned to 0.15 explicitly (not the `zig` alias): nixpkgs-unstable's
            # `zig` attr floated to 0.16.0 on this flake.lock's pinned nixpkgs
            # revision, which breaks build.zig (0.16 moved std.fs.cwd() etc. to
            # std.Io.Dir). CI (.github/workflows/ci.yml) pins the same 0.15.2 via
            # mlugg/setup-zig@v2 -- keep this in lockstep with that.
            zig_0_15
            (python3.withPackages (ps: [ ps.toml ]))
            unixtools.netstat
            nettools
            valgrind
            actionlint
            # bench/: nginx = the open-source baseline (ngx_http_dav_module is
            # in nixpkgs' default nginx build, giving PUT), oha + wrk = the two
            # load generators (see bench/bench.sh, bench/differential.sh).
            nginx
            oha
            wrk
            # bench/analysis: Julia turns bench/results CSVs into the SVG
            # figures embedded by docs/performance.md. withPackages builds a
            # hermetic depot (packages pre-instantiated at nix-build time, no
            # ~/.julia network fetch at run time).
            (julia.withPackages [ "CSV" "DataFrames" "Plots" ])
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        build = self.packages.${pkgs.system}.default;
      });
    };
}
