# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Nix flake for game-server-admin
#
# NOTE: guix.scm is the PRIMARY development environment. This flake is provided
# as a FALLBACK for contributors who use Nix instead of Guix. The .envrc checks
# for Guix first, then falls back to Nix.
#
# Usage:
#   nix develop          # Enter development shell
#   nix build            # Build the project
#   nix flake check      # Run checks
#   nix flake show       # Show flake outputs
#
# With direnv (.envrc already configured):
#   direnv allow         # Auto-enters shell on cd
#
# Stack: Zig FFI + Idris2 ABI + Ephapax GUI (Gossamer) + VeriSimDB

{
  description = "game-server-admin — RSR-compliant project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Common development tools present in every RSR project.
        commonTools = with pkgs; [
          git
          just
          nickel
          curl
          bash
          coreutils
        ];

        # ---------------------------------------------------------------
        # Language-specific packages: uncomment the stacks you need.
        # ---------------------------------------------------------------
        #
        # Rust:
        #   rustc cargo clippy rustfmt rust-analyzer
        #
        # Elixir:
        #   elixir erlang
        #
        # Gleam:
        #   gleam erlang
        #
        # Zig:
        #   zig zls
        #
        # Haskell:
        #   ghc cabal-install haskell-language-server
        #
        # Idris2:
        #   idris2
        #
        # OCaml:
        #   ocaml dune_3 ocaml-lsp
        #
        # ReScript (via Deno):
        #   deno
        #
        # Julia:
        #   julia
        #
        # Ada/SPARK:
        #   gnat gprbuild
        #
        # ---------------------------------------------------------------
        languageTools = with pkgs; [
          zig     # FFI layer build system and compiler
          zls     # Zig language server
          idris2  # ABI formal definitions
        ];

      in
      {
        # ---------------------------------------------------------------
        # Development shell — `nix develop`
        # ---------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "game-server-admin-dev";

          buildInputs = commonTools ++ languageTools;

          # Environment variables available inside the shell.
          env = {
            PROJECT_NAME = "game-server-admin";
            RSR_TIER = "infrastructure";
          };

          shellHook = ''
            echo ""
            echo "  game-server-admin — development shell"
            echo "  Nix:    $(nix --version 2>/dev/null || echo 'unknown')"
            echo "  Just:   $(just --version 2>/dev/null || echo 'not found')"
            echo ""
            echo "  Run 'just' to see available recipes."
            echo ""

            # Source .envrc manually when direnv is not managing the shell.
            # This keeps project env vars (PROJECT_NAME, DATABASE_URL, etc.)
            # consistent whether you enter via 'nix develop' or 'direnv allow'.
            if [ -z "''${DIRENV_IN_ENVRC:-}" ] && [ -f .envrc ]; then
              # Only source the non-nix parts to avoid recursion.
              export PROJECT_NAME="game-server-admin"
              export RSR_TIER="infrastructure"
              if [ -f .env ]; then
                set -a
                . .env
                set +a
              fi
            fi
          '';
        };

        # ---------------------------------------------------------------
        # Package — `nix build`
        # ---------------------------------------------------------------
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "game-server-admin";
          version = "0.1.0";

          src = self;

          nativeBuildInputs = [ pkgs.zig ];

          # Build the Zig FFI library and standalone CLI binary.
          buildPhase = ''
            cd src/interface/ffi
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin $out/lib $out/share/doc $out/share/game-server-admin/profiles
            cp src/interface/ffi/zig-out/bin/gsa $out/bin/
            cp src/interface/ffi/zig-out/lib/libgsa.so $out/lib/ 2>/dev/null || true
            cp -r profiles/* $out/share/game-server-admin/profiles/
            cp README.adoc $out/share/doc/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Universal game server probe, config management, and administration via Gossamer + VeriSimDB";
            homepage = "https://github.com/hyperpolymath/game-server-admin";
            license = licenses.mpl20; # AGPL-3.0-or-later extends MPL-2.0
            maintainers = [];
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };
      }
    );
}
