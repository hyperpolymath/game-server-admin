# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Containerfile for game-server-admin (GSA)
#
# Builds the Zig FFI layer into a standalone CLI binary and packages it
# inside a minimal Chainguard static image.  The resulting container can
# probe game servers, query VeriSimDB, and send Groove alerts.
#
# Build: podman build -t game-server-admin:latest -f Containerfile .
# Run:   podman run --rm -it game-server-admin:latest status
# Seal:  selur seal game-server-admin:latest

# --- Build stage ---
FROM cgr.dev/chainguard/wolfi-base:latest AS build

# Install Zig for building the FFI layer and CLI
RUN apk add --no-cache zig curl

WORKDIR /build
COPY . .

# Build the shared library and CLI binary with release optimisations.
# The Zig build system produces:
#   zig-out/bin/gsa      — standalone CLI executable
#   zig-out/lib/libgsa.so — shared library for Gossamer
RUN cd src/interface/ffi && zig build -Doptimize=ReleaseSafe

# --- Runtime stage ---
FROM cgr.dev/chainguard/static:latest

# Copy the built CLI binary and shared library
COPY --from=build /build/src/interface/ffi/zig-out/bin/gsa /usr/local/bin/gsa
COPY --from=build /build/src/interface/ffi/zig-out/lib/libgsa.so /usr/local/lib/libgsa.so

# Copy game profiles so the CLI can list and validate them
COPY --from=build /build/profiles/ /app/profiles/

# Copy the Groove well-known manifest
COPY --from=build /build/.well-known/ /app/.well-known/

# Non-root user (chainguard images default to nonroot)
USER nonroot

# Default environment variables
ENV GSA_VERISIMDB_URL="http://localhost:8090" \
    GSA_PROFILES_DIR="/app/profiles"

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/gsa"]
CMD ["status"]
