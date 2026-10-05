#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Install a pinned, hash-verified GHC + cabal-install toolchain for CI —
# no third-party action.
#
# Why this exists: the repo's Actions policy admits only actions from
# hyperpolymath-owned repos, GitHub-created repos, or Marketplace-verified
# creators — and every action must be pinned to a full-length commit SHA or a
# full semver tag. `haskell-actions/setup` is none of those, so `GitHub Pages`
# ended in startup_failure before running a single step
# (game-server-admin#103). This script needs no action at all.
#
# Trust chain: both tarballs are fetched from downloads.haskell.org over HTTPS
# and must match the sha256 pinned below, or the step fails. The pins are
# transcribed from GHCup's official release metadata
# (haskell/ghcup-metadata, ghcup-0.0.7.yaml, published with a minisign
# signature in ghcup-0.0.7.yaml.sig) — the same table ghcup itself installs
# from. The deb11 bindists are chosen because they are the generic Linux
# builds and run unchanged on the ubuntu-24.04 runner image.
#
# To bump: take the new dlUri/dlHash pair out of ghcup-0.0.7.yaml and change
# the version and digest together. Never change one without the other.
#
# Usage: bash scripts/setup-haskell.sh
# Puts `ghc` and `cabal` on PATH for subsequent steps via $GITHUB_PATH.

set -euo pipefail

GHC_VERSION="9.8.2"
GHC_TARBALL="ghc-${GHC_VERSION}-x86_64-deb11-linux.tar.xz"
GHC_URL="https://downloads.haskell.org/~ghc/${GHC_VERSION}/${GHC_TARBALL}"
GHC_SHA256="ee9d424c614dd4b92b0104e812fb92016bf3d3ffd5e51a8af544634b9d817028"

CABAL_VERSION="3.10.2.0"
CABAL_TARBALL="cabal-install-${CABAL_VERSION}-x86_64-linux-deb11.tar.xz"
CABAL_URL="https://downloads.haskell.org/cabal/cabal-install-${CABAL_VERSION}/${CABAL_TARBALL}"
CABAL_SHA256="9ca5625c89e8fcada02edced5048c3a3db0254e2bef1eb792d549d633222b108"

tmp_root="${RUNNER_TEMP:?RUNNER_TEMP must be set (GitHub Actions)}/haskell-setup"
prefix="${RUNNER_TEMP}/haskell"
mkdir -p "$tmp_root" "$prefix/bin"

# The GHC bindist is dynamically linked against gmp/ncurses/zlib, and cabal
# needs the matching C headers to build packages such as pandoc. The runner
# image does not guarantee all of them.
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  libgmp-dev libtinfo6 libncurses-dev zlib1g-dev

fetch_verify() {
  # fetch_verify <url> <sha256> <destination tarball>
  # Download an HTTPS tarball to the destination and check its expected SHA-256.
  # Overwrites an existing destination; a checksum failure leaves the file there.
  # Returns zero on a match. With this script's set -e, download or verification
  # failures abort setup without removing the destination file.
  local url="$1" want="$2" dest="$3"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 5 \
    -o "$dest" "$url"
  echo "${want}  ${dest}" | sha256sum -c -
}

fetch_verify "$GHC_URL" "$GHC_SHA256" "${tmp_root}/${GHC_TARBALL}"
fetch_verify "$CABAL_URL" "$CABAL_SHA256" "${tmp_root}/${CABAL_TARBALL}"

tar -xJf "${tmp_root}/${GHC_TARBALL}" -C "$tmp_root"
tar -xJf "${tmp_root}/${CABAL_TARBALL}" -C "$tmp_root"

# A GHC bindist is relocatable only after `configure` rewrites the wrapper
# scripts, so do the real install into a throwaway prefix rather than using it
# in place.
( cd "${tmp_root}/ghc-${GHC_VERSION}-x86_64-unknown-linux" \
  && ./configure --prefix="$prefix" \
  && make install )

install -m 0755 "${tmp_root}/cabal" "${prefix}/bin/cabal"

rm -rf "$tmp_root"

got_ghc="$("${prefix}/bin/ghc" --numeric-version)"
if [[ "$got_ghc" != "$GHC_VERSION" ]]; then
  echo "::error::installed ghc reports '${got_ghc}', expected '${GHC_VERSION}'" >&2
  exit 1
fi

got_cabal="$("${prefix}/bin/cabal" --numeric-version)"
if [[ "$got_cabal" != "$CABAL_VERSION" ]]; then
  echo "::error::installed cabal reports '${got_cabal}', expected '${CABAL_VERSION}'" >&2
  exit 1
fi

echo "${prefix}/bin" >> "${GITHUB_PATH:?GITHUB_PATH must be set (GitHub Actions)}"
echo "Installed ghc ${got_ghc} and cabal-install ${got_cabal} into ${prefix}"
