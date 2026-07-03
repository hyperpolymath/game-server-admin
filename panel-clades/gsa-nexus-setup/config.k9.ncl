# SPDX-License-Identifier: MPL-2.0
{
  pedigree = {
    name = "gsa-nexus-setup-config",
    version = "1.0.0",
    author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    leash = 'Kennel,
  },
  panel = {
    id = "GsaNexusSetup",
    short_name = "Nexus",
    description = "Guided 7-step wizard to deploy a new managed game server",
    has_backend = true,
    clade_id = "gsa-nexus-setup",
    isolation_tier = "native",
  },
  wiring = {
    model_slice = "gsaNexusSetup",
    msg_namespace = "gsaNexusSetupMsg",
    view_route = "PanelGsaNexusSetup",
    module_name = "GsaNexusSetup",
  },
  obligations = {
    requires_tests = true,
    requires_backend_health = true,
    requires_clade_manifest = true,
  },
}
