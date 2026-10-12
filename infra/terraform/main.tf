locals {
  budget_host     = "${var.budget_subdomain}.${var.domain}"
  mcp_host        = "${var.mcp_subdomain}.${var.domain}"
  college_host    = "college.${var.domain}"
  actual_api_host = "${var.actual_api_subdomain}.${var.domain}"
  landing_host    = var.domain # apex — the hub landing page lives at the zone root
}

# ---------------------------------------------------------------------------
# Compute: one always-on Hetzner VPS + a persistent data volume.
# This box runs Docker: the Actual container, Caddy, and (later) the Hub.
# ---------------------------------------------------------------------------

resource "hcloud_ssh_key" "admin" {
  name       = "household-os-admin"
  public_key = var.admin_ssh_public_key
}

resource "hcloud_server" "hub" {
  name        = "household-os"
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"
  ssh_keys    = [hcloud_ssh_key.admin.id]

  # Installs Docker + compose plugin on first boot. The data volume is
  # formatted/mounted manually in the install doc (Hetzner volume device
  # paths are easier to handle by hand on first run).
  user_data = file("${path.module}/cloud-init.yaml")

  labels = {
    project = "household-os"
    role    = "hub"
  }

  # cloud-init runs only at first boot; ignore drift in user_data so Terraform
  # doesn't force-replace the live server when cloud-init.yaml is updated.
  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_volume" "data" {
  name      = "household-os-data"
  size      = var.volume_size_gb
  server_id = hcloud_server.hub.id
  automount = false
  format    = "ext4"
}

# Firewall: SSH from you only; HTTP/HTTPS from anywhere (Cloudflare proxies in
# front, so the public sees Cloudflare, and the origin only needs 80/443 open).
#
# Admin SSH has two mutually exclusive shapes, chosen by var.ssh_over_tailscale_only:
#   false (default) → the original rule: public tcp/22 open only from var.admin_ip_cidr.
#   true            → NO public tcp/22 rule at all; admin SSH is reachable only over the
#                     Tailscale tailnet (WireGuard arrives on tailscale0, which the cloud
#                     firewall's public-interface rules don't govern). See
#                     docs/install-tailscale.md. Flip to true ONLY after confirming you can
#                     SSH in over the 100.x tailnet address, or you lock out the public path.
resource "hcloud_firewall" "hub" {
  name = "household-os-fw"

  # Public SSH — present only while NOT tailnet-only.
  dynamic "rule" {
    for_each = var.ssh_over_tailscale_only ? [] : [1]
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [var.admin_ip_cidr]
    }
  }

  # Tailscale direct-connection port (WireGuard). Opened only when SSH is tailnet-only,
  # so Tailscale can form a direct P2P link instead of relaying via a DERP server. Safe
  # to expose: inbound packets are authenticated by WireGuard; unauthenticated traffic is
  # dropped by tailscaled, not admitted to the host. Optional — SSH still works over a
  # DERP relay without it, just with more latency.
  dynamic "rule" {
    for_each = var.ssh_over_tailscale_only ? [1] : []
    content {
      direction  = "in"
      protocol   = "udp"
      port       = "41641"
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_firewall_attachment" "hub" {
  firewall_id = hcloud_firewall.hub.id
  server_ids  = [hcloud_server.hub.id]
}

# ---------------------------------------------------------------------------
# Edge: Cloudflare DNS (proxied) + Origin cert + Access (Google SSO + allowlist).
# ---------------------------------------------------------------------------

resource "cloudflare_record" "budget" {
  zone_id = var.cloudflare_zone_id
  name    = var.budget_subdomain
  type    = "A"
  content = hcloud_server.hub.ipv4_address
  proxied = true # orange cloud: Cloudflare terminates the public TLS + runs Access
  ttl     = 1
}

# A long-lived Origin certificate so Caddy can serve TLS to Cloudflare with
# SSL mode "Full (strict)". Avoids ACME-through-proxy gotchas entirely.
resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  subject {
    common_name = local.budget_host
  }
  dns_names = [local.budget_host]
}

resource "cloudflare_origin_ca_certificate" "budget" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [local.budget_host]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# The Google login method you added in Zero Trust > Settings > Authentication
# (install doc step 2a). Looked up by name so we don't hardcode its UUID.
data "cloudflare_zero_trust_access_identity_provider" "google" {
  account_id = var.cloudflare_account_id
  name       = var.google_idp_name
}

# Cloudflare Access: only allowlisted Google accounts reach Actual at all.
resource "cloudflare_zero_trust_access_application" "budget" {
  account_id           = var.cloudflare_account_id
  name                 = "Household OS — Budget (Actual)"
  domain               = local.budget_host
  type                 = "self_hosted"
  session_duration     = var.access_session_duration
  app_launcher_visible = true

  # auto_redirect_to_identity requires exactly one entry in allowed_idps.
  allowed_idps              = [data.cloudflare_zero_trust_access_identity_provider.google.id]
  auto_redirect_to_identity = true
}

resource "cloudflare_zero_trust_access_policy" "budget_family" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.budget.id
  name           = "Family allowlist"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.family_emails
  }
}

# ---------------------------------------------------------------------------
# Edge: College Fund app (college.stimpert.haus).
# ---------------------------------------------------------------------------

resource "cloudflare_record" "college" {
  zone_id = var.cloudflare_zone_id
  name    = "college"
  type    = "A"
  content = hcloud_server.hub.ipv4_address
  proxied = true
  ttl     = 1
}

resource "tls_private_key" "college_origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "college_origin" {
  private_key_pem = tls_private_key.college_origin.private_key_pem
  subject {
    common_name = local.college_host
  }
  dns_names = [local.college_host]
}

resource "cloudflare_origin_ca_certificate" "college" {
  csr                = tls_cert_request.college_origin.cert_request_pem
  hostnames          = [local.college_host]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

resource "cloudflare_zero_trust_access_application" "college" {
  account_id           = var.cloudflare_account_id
  name                 = "Household OS — College Fund Calculator"
  domain               = local.college_host
  type                 = "self_hosted"
  session_duration     = var.access_session_duration
  app_launcher_visible = true

  allowed_idps              = [data.cloudflare_zero_trust_access_identity_provider.google.id]
  auto_redirect_to_identity = true
}

resource "cloudflare_zero_trust_access_policy" "college_family" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.college.id
  name           = "Family allowlist"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.family_emails
  }
}

# ---------------------------------------------------------------------------
# Edge: Household OS hub landing page (apex — stimpert.haus).
#
# Static hub page served by Caddy's file_server (no app container). Same edge
# pattern as the college app above — proxied A record + 15-year Origin cert +
# Cloudflare Access (Google SSO + family allowlist). The only differences are:
#   • It lives at the ZONE APEX, so the DNS record name is "@" (var.domain).
#   • ⚠️ Apex may already carry records (email/MX, a redirect, a placeholder A).
#     Those are NOT managed here (MX/TXT are separate record types); but if a
#     conflicting apex A/AAAA already exists, reconcile it so this proxied A wins.
#     See docs/runbook-landing-updates.md §1d.
# ---------------------------------------------------------------------------

resource "cloudflare_record" "landing" {
  zone_id = var.cloudflare_zone_id
  name    = "@" # zone apex
  type    = "A"
  content = hcloud_server.hub.ipv4_address
  proxied = true
  ttl     = 1
}

resource "tls_private_key" "landing_origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "landing_origin" {
  private_key_pem = tls_private_key.landing_origin.private_key_pem
  subject {
    common_name = local.landing_host
  }
  dns_names = [local.landing_host]
}

resource "cloudflare_origin_ca_certificate" "landing" {
  csr                = tls_cert_request.landing_origin.cert_request_pem
  hostnames          = [local.landing_host]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

resource "cloudflare_zero_trust_access_application" "landing" {
  account_id           = var.cloudflare_account_id
  name                 = "Household OS — Hub landing"
  domain               = local.landing_host
  type                 = "self_hosted"
  session_duration     = var.access_session_duration
  app_launcher_visible = true

  allowed_idps              = [data.cloudflare_zero_trust_access_identity_provider.google.id]
  auto_redirect_to_identity = true
}

resource "cloudflare_zero_trust_access_policy" "landing_family" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.landing.id
  name           = "Family allowlist"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.family_emails
  }
}

# ---------------------------------------------------------------------------
# Edge: MCP budget server (agigante80/actual-mcp-server). See ADR-0002.
#
# This host serves the AI-facing MCP endpoint, NOT a browser app. Two things
# differ deliberately from the budget host above:
#
#   1. NO Cloudflare Access application. Access only admits interactive browser
#      SSO; an MCP client (Claude.ai/Desktop connector) is a non-browser client
#      and would receive the Access login page instead of the server — the same
#      failure the native Actual apps hit (install-actual.md §10f). The gate here
#      is the MCP server's OWN auth: a static Bearer token (MCP_SSE_AUTHORIZATION)
#      for v1, upgradeable to OIDC/JWT. See the eval doc for the threat model.
#   2. Still Cloudflare-proxied (orange cloud) so the origin IP stays hidden and
#      we get TLS + WAF + rate-limiting in front of the token gate.
# ---------------------------------------------------------------------------

resource "cloudflare_record" "mcp" {
  zone_id = var.cloudflare_zone_id
  name    = var.mcp_subdomain
  type    = "A"
  content = hcloud_server.hub.ipv4_address
  proxied = true # orange cloud: TLS + WAF in front; NO Access app on this host (see above).
  ttl     = 1
}

# Separate Origin keypair + cert for the MCP host (the budget cert only covers
# budget_host). Same 15-year origin-CA pattern so Caddy can serve Full (strict).
resource "tls_private_key" "mcp_origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "mcp_origin" {
  private_key_pem = tls_private_key.mcp_origin.private_key_pem
  subject {
    common_name = local.mcp_host
  }
  dns_names = [local.mcp_host]
}

resource "cloudflare_origin_ca_certificate" "mcp" {
  csr                = tls_cert_request.mcp_origin.cert_request_pem
  hostnames          = [local.mcp_host]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# ---------------------------------------------------------------------------
# OPT-IN (ADR-0003): Cloudflare Access SERVICE-TOKEN layer on the MCP host.
#
# All three resources below are gated on var.enable_mcp_access_service_token and
# default OFF. They add a non-interactive Access application in front of the MCP
# server's own Bearer/OIDC gate (defense in depth), accepting a service token.
#
#   ⚠️ READ THIS BEFORE ENABLING. This is a DELIBERATE, NARROW reversal of the
#   ADR-0002 rule that the MCP host has NO Access app. It is NOT the failure the
#   docs/mcp-budget-server.md troubleshooting table warns about: that failure is an
#   *interactive* Access app bouncing non-browser MCP clients to the Google login
#   page. Here the policy decision is `non_identity` and the only included rule is a
#   SERVICE TOKEN — a client presenting the CF-Access-Client-Id / CF-Access-Client-
#   Secret headers is admitted with NO browser redirect. There is no IdP/Google leg
#   on this app, so it cannot bounce to a login page. Enable only after confirming
#   your MCP client can attach those two headers (ADR-0003 client-capability unknown).
#
# The BUDGET host's Access app (above) is untouched — Actual stays on Google SSO.
# ---------------------------------------------------------------------------

resource "cloudflare_zero_trust_access_service_token" "mcp" {
  count      = var.enable_mcp_access_service_token ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "Household OS — MCP budget (service token)"
  # client_secret is shown ONLY on create/rotate; capture it from the
  # mcp_access_service_token_secret output and store it with the client.
}

resource "cloudflare_zero_trust_access_application" "mcp" {
  count            = var.enable_mcp_access_service_token ? 1 : 0
  account_id       = var.cloudflare_account_id
  name             = "Household OS — MCP budget (service token)"
  domain           = local.mcp_host
  type             = "self_hosted"
  session_duration = var.access_session_duration

  # Non-interactive endpoint: keep it out of the app launcher and DO NOT
  # auto-redirect to an IdP — admission is by service token only, so there is
  # no Google login leg that could bounce a non-browser MCP client.
  app_launcher_visible = false
}

resource "cloudflare_zero_trust_access_policy" "mcp_service_token" {
  count          = var.enable_mcp_access_service_token ? 1 : 0
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.mcp[0].id
  name           = "MCP service token"
  precedence     = 1
  decision       = "non_identity" # service-token auth: no interactive identity required

  include {
    service_token = [cloudflare_zero_trust_access_service_token.mcp[0].id]
  }
}

# Bypass policy: allows all traffic through at the CF edge so non-browser MCP
# clients (e.g. Claude connector, which can't send service-token headers) are
# not blocked. The real auth gate is the MCP server's own Bearer/OIDC check.
# The app is kept alive so its AUD remains valid for OIDC JWT validation via
# `cloudflared access token`.
resource "cloudflare_zero_trust_access_policy" "mcp_bypass" {
  count          = var.enable_mcp_access_service_token ? 1 : 0
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.mcp[0].id
  name           = "MCP bypass (edge passthrough)"
  precedence     = 2
  decision       = "bypass"

  include {
    everyone = true
  }
}

# ---------------------------------------------------------------------------
# ADR-0005 (the decision): Cloudflare Access SaaS-OIDC application — the MCP
# server's OIDC ISSUER.
#
# Both resources below are gated on var.enable_mcp_saas_oidc and default OFF.
# This is the DECIDED per-user auth path (ADR-0005 supersedes ADR-0004's
# Google-direct), distinct from every MCP block above it:
#
#   • Unlike the ADR-0003 service-token app (a SELF-HOSTED Access app on the MCP
#     origin, gated on var.enable_mcp_access_service_token), this is a SaaS app
#     of type = "saas" with auth_type = "oidc". A SaaS-OIDC app IS a full OIDC
#     authorization server — it publishes authorization_endpoint / token_endpoint
#     and a same-origin JWKS, and runs the OAuth 2.1 PKCE code flow Claude needs.
#     The self-hosted mode that ADR-0003 tried has none of those (no token
#     endpoint), which is why that attempt failed.
#   • The MCP origin keeps NO self-hosted Access gate (ADR-0002 rule stands) —
#     auth happens out of band at these SaaS endpoints, so a non-browser MCP
#     client is never bounced to an interactive login page.
#   • The family allowlist lives HERE (the policy below), enforced at login, so it
#     is NOT duplicated into AUTH_BUDGET_ACL — that narrows to per-budget scoping.
#
# Issuer is PER-APP: https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<client_id>
# (see the mcp_saas_oidc_issuer output). The access token's `aud` is the CLIENT'S
# REDIRECT URI (one of var.mcp_oauth_redirect_uris), not the client_id, so those URIs
# go in the MCP server's OIDC_ACCEPTED_AUDIENCES. The client_id/secret go into each
# AI-client connector at cutover (docs/mcp-budget-server.md §5, §7g).
#
# ⚠️ Confirm the saas_app OIDC schema against the pinned cloudflare provider
# (4.52.x, see versions.tf / .terraform.lock.hcl) with `terraform validate`
# before applying — the block's attribute names drift across provider versions.
# ---------------------------------------------------------------------------

resource "cloudflare_zero_trust_access_application" "mcp_saas_oidc" {
  count      = var.enable_mcp_saas_oidc ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "Household OS — MCP (SaaS OIDC)"
  type       = "saas"

  # App session duration governs how long the login persists before a fresh
  # interactive auth is required; the access/refresh token lifetimes below govern
  # silent token refresh within that window. Both feed "stop re-auth prompts."
  session_duration = var.access_session_duration

  saas_app {
    auth_type     = "oidc"
    redirect_uris = var.mcp_oauth_redirect_uris
    # openid + email: the MCP server keys AUTH_BUDGET_ACL off the email claim.
    scopes = ["openid", "email"]
    # authorization_code_with_pkce = the PKCE code flow Claude uses; refresh_tokens =
    # durable, revocable refresh for seamless sessions (ADR-0005 token-lifetime
    # mechanics). Must be the _with_pkce grant: the CF API rejects
    # allow_pkce_without_client_secret alongside plain authorization_code (12130).
    grant_types = ["authorization_code_with_pkce", "refresh_tokens"]

    # Don't require the client secret at the token endpoint for the PKCE grant —
    # supports clients that register as public. A client that does send the secret
    # still works.
    allow_pkce_without_client_secret = true

    # Short access token + longer refresh token: durability without a long-lived
    # access token on a write-capable financial endpoint.
    access_token_lifetime = var.mcp_oidc_access_token_lifetime
    refresh_token_options {
      lifetime = var.mcp_oidc_refresh_token_lifetime
    }
  }
}

# Family allowlist for the SaaS-OIDC app — the SINGLE place the coarse family gate
# lives on the CF path (reuses var.family_emails, same as the budget/college apps).
# Enforced by CF Access at login, so AUTH_BUDGET_ACL is not the family gate here.
resource "cloudflare_zero_trust_access_policy" "mcp_saas_family" {
  count          = var.enable_mcp_saas_oidc ? 1 : 0
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.mcp_saas_oidc[0].id
  name           = "Family allowlist"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.family_emails
  }
}

# ---------------------------------------------------------------------------
# Edge: Actual HTTP REST API sidecar (jhonderson/actual-http-api).
#
# Same pattern as the MCP host above — Cloudflare-proxied for TLS + WAF, but
# deliberately NO Cloudflare Access application. The gate is the API_KEY in
# actual-http-api.env. See docs/install-actual-http-api.md for the threat model.
# ---------------------------------------------------------------------------

resource "cloudflare_record" "actual_api" {
  zone_id = var.cloudflare_zone_id
  name    = var.actual_api_subdomain
  type    = "A"
  content = hcloud_server.hub.ipv4_address
  proxied = true
  ttl     = 1
}

resource "tls_private_key" "actual_api_origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "actual_api_origin" {
  private_key_pem = tls_private_key.actual_api_origin.private_key_pem
  subject {
    common_name = local.actual_api_host
  }
  dns_names = [local.actual_api_host]
}

resource "cloudflare_origin_ca_certificate" "actual_api" {
  csr                = tls_cert_request.actual_api_origin.cert_request_pem
  hostnames          = [local.actual_api_host]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# ---------------------------------------------------------------------------
# Backups: R2 bucket for Litestream (Hub SQLite) + weekly Actual exports.
# ---------------------------------------------------------------------------

resource "cloudflare_r2_bucket" "backups" {
  account_id = var.cloudflare_account_id
  name       = "household-os-backups"
  location   = "ENAM"
}
