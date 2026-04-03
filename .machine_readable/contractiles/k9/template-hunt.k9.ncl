K9!
# SPDX-License-Identifier: PMPL-1.0-or-later
# K9 Hunt-level contractile: Game Server Admin full deployment
# Security Level: Hunt (full system access)
# ⚠️ SIGNATURE REQUIRED - Review carefully before use

{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "deployment",
    security = {
      leash = 'Hunt,
      trust_level = "full-system-access",
      allow_network = true,
      allow_filesystem_write = true,
      allow_subprocess = true,
      signature_required = true,
    },
    metadata = {
      name = "gsa-deploy",
      version = "1.0.0",
      description = "Full deployment of Game Server Admin: builds Zig FFI library, starts VeriSimDB containers, installs desktop entry and quadlets, and runs the e2e smoke test to verify the pipeline is healthy.",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
    warnings = [
      "This component has full system access",
      "Only run from trusted sources with verified signatures",
      "Review all Just recipes before execution",
      "Use dry-run mode first: ./must --dry-run run your-file.k9.ncl",
    ],
    side_effects = [
      "Creates Zig build artefacts in src/interface/ffi/zig-out/",
      "Starts Podman containers: gsa-verisimdb (port 8090) and gsa-verisimdb-backup (port 8091)",
      "Installs systemd user units via Podman Quadlets under ~/.config/containers/systemd/",
      "Installs desktop entry and launcher to ~/.local/share/applications/ and ~/.local/bin/",
      "Writes to GSA_VERISIMDB_URL (default: http://[::1]:8090) during health checks",
    ],
  },

  # Configuration with contracts (Yard-level validation)
  config = {
    target_dir
      | String
      | std.string.NonEmpty
      = ".",

    dry_run | Bool = false,

    verisimdb_url
      | String
      | std.string.NonEmpty
      = "http://[::1]:8090",

    profiles_dir
      | String
      | std.string.NonEmpty
      = "./profiles",
  },

  # Just recipes for execution
  recipes = {
    default = {
      recipe = "deploy",
      description = "Full GSA deployment: build -> containers -> install -> verify",
    },

    "deploy" = {
      dependencies = ["build", "verisimdb-up", "install-desktop", "install-quadlets", "verify"],
      commands = [
        "echo '✓ GSA deployment complete'",
      ],
    },

    "build" = {
      description = "Build Zig FFI library and CLI binary",
      commands = [
        "just build",
      ],
    },

    "verisimdb-up" = {
      description = "Start VeriSimDB main and backup containers",
      commands = [
        "just verisimdb-up",
        "just verisimdb-backup-up",
      ],
    },

    "install-desktop" = {
      description = "Install desktop entry and launcher",
      commands = [
        "./scripts/install-desktop.sh",
      ],
    },

    "install-quadlets" = {
      description = "Install Podman Quadlet systemd units",
      commands = [
        "./scripts/install-quadlets.sh",
      ],
    },

    "verify" = {
      description = "Run e2e smoke test to verify pipeline health",
      commands = [
        "just test-smoke",
      ],
    },

    "clean" = {
      description = "Remove build artefacts and stop containers",
      commands = [
        "echo '⚠️  This will stop containers and delete build artefacts - waiting 3 seconds...'",
        "sleep 3",
        "just verisimdb-down || true",
        "just verisimdb-backup-down || true",
        "rm -rf src/interface/ffi/zig-out/",
      ],
    },
  },

  # Validation (Yard-level checks before Hunt execution)
  validation = {
    check_target_dir = std.string.length config.target_dir > 0,
    check_verisimdb_url = std.string.length config.verisimdb_url > 0,
  },
}

# Usage:
# 1. Review side_effects and ensure they match your environment
# 2. Optionally override config: gsa-deploy.k9.ncl with custom verisimdb_url
# 3. Test with dry-run: ./must --dry-run run gsa-deploy.k9.ncl
# 4. Review dry-run output carefully
# 5. Sign the component: ./must sign gsa-deploy.k9.ncl
# 6. Execute: ./must run gsa-deploy.k9.ncl
#
# Security checklist:
# ✓ All placeholders filled in with GSA-specific content
# ✓ side_effects documented accurately
# ✓ Commands reviewed for safety
# ✓ No hardcoded secrets or credentials
# ✓ Proper error handling delegated to just recipes
# ✓ Tested in dry-run mode
# ✓ Component signed with trusted key
