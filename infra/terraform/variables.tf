# ---- Provider credentials -------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Project > Security > API Tokens, Read & Write)."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token scoped to: Zone:DNS:Edit, Account:Access (Apps & Policies):Edit,
    Account:Access (Orgs, Identity Providers & Groups):Read (to look up the Google IdP),
    Account:Workers R2 Storage:Edit, Zone:SSL and Certificates:Edit (for the Origin cert).
  EOT
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (dashboard sidebar, or `Manage Account`)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for your household domain."
  type        = string
}

# ---- Naming / DNS ---------------------------------------------------------

variable "domain" {
  description = "Apex household domain, e.g. example.com."
  type        = string
}

variable "budget_subdomain" {
  description = "Subdomain Actual is served at. Final host = <budget_subdomain>.<domain>."
  type        = string
  default     = "budget"
}

variable "mcp_subdomain" {
  description = <<-EOT
    Subdomain the AI-facing MCP budget server is served at (ADR-0002). Final host =
    <mcp_subdomain>.<domain>. NOTE: unlike the budget host, this one is deliberately
    NOT behind an interactive Cloudflare Access app — the gate is the MCP server's own
    Bearer/OIDC auth, because an MCP client is a non-browser client that an interactive
    Access app would block. (An optional non-interactive SERVICE-TOKEN Access layer can
    be turned on via var.enable_mcp_access_service_token — ADR-0003.)
  EOT
  type        = string
  default     = "mcp-budget"
}

variable "actual_api_subdomain" {
  description = <<-EOT
    Subdomain the Actual HTTP REST API sidecar is served at. Final host =
    <actual_api_subdomain>.<domain>. Like the MCP host, this is NOT behind Cloudflare
    Access — programmatic API clients can't do browser SSO. The gate is the API_KEY
    in actual-http-api.env. See docs/install-actual-http-api.md.
  EOT
  type        = string
  default     = "actual-api"
}

# ---- Access control -------------------------------------------------------

variable "enable_mcp_access_service_token" {
  description = <<-EOT
    OPT-IN (ADR-0003): put the MCP host behind a Cloudflare Access application that
    accepts a non-identity SERVICE TOKEN as a defense-in-depth layer in front of the
    MCP server's own Bearer/OIDC gate. This is a DELIBERATE, NARROW reversal of
    ADR-0002's "no Access app on the MCP host" rule — and is NOT the misconfiguration
    the docs/mcp-budget-server.md troubleshooting table warns about (an interactive
    Access app that bounces non-browser clients to the Google login page). The policy
    here is `non_identity` + service token, so a client sending the CF-Access-Client-Id
    / CF-Access-Client-Secret headers is admitted with NO browser redirect.

    Leave false until you have confirmed your MCP client (Claude.ai / Desktop
    connector) can attach those two custom headers; otherwise enabling this will block
    a client that cannot. The budget host's Access app is unaffected either way.
  EOT
  type        = bool
  default     = false
}

variable "enable_mcp_saas_oidc" {
  description = <<-EOT
    ADR-0005 (the decision): stand up a Cloudflare Access **SaaS** application (OIDC
    protocol) to act as the MCP server's OIDC issuer. This is the recommended per-user
    auth path — CF Access is the IdP (per-app issuer under the team domain), the
    family allowlist lives in ONE place (the CF Access policy, not duplicated into
    AUTH_BUDGET_ACL), JWKS is same-origin, and access/refresh token lifetimes are
    configurable to "stop re-auth prompts."

    This is a SaaS (OIDC) app, NOT the self-hosted app that failed in ADR-0003, and NOT
    the same thing as var.enable_mcp_access_service_token (ADR-0003's interim edge
    service-token layer). It leaves the MCP origin's proxied DNS record untouched — auth
    happens out of band at the CF SaaS endpoints via the OAuth 2.1 PKCE flow.

    Defaults OFF: enabling it creates the SaaS app + client credentials. Turn on at
    cutover (docs/mcp-budget-server.md §7), after which you copy the client ID/secret
    into mcp.env and flip AUTH_PROVIDER=oidc. Requires var.mcp_oauth_redirect_uris.
  EOT
  type        = bool
  default     = false
}

variable "cloudflare_team_domain" {
  description = <<-EOT
    Your Cloudflare Zero Trust team domain, e.g. "myteam.cloudflareaccess.com" (Zero Trust
    → Settings → Custom Pages). Only used to print the exact MCP OIDC issuer in the
    mcp_saas_oidc_issuer output — provider v4 does not expose it. Optional.
  EOT
  type        = string
  default     = ""
}

variable "mcp_oauth_redirect_uris" {
  description = <<-EOT
    OAuth redirect/callback URIs registered on the MCP SaaS-OIDC app (ADR-0005), one per
    AI client that connects (Claude.ai, Desktop, Code). Only used when
    var.enable_mcp_saas_oidc is true. Exact URIs vary by client version — start from the
    client's connector docs (e.g. https://claude.ai/api/mcp/auth_callback) and extend.
  EOT
  type        = list(string)
  default     = []
}

variable "mcp_oidc_access_token_lifetime" {
  description = <<-EOT
    Access-token lifetime for the MCP SaaS-OIDC app (ADR-0005). Keep this SHORT — a
    long-lived access token on a write-capable financial endpoint enlarges the leak
    blast-radius. Durability comes from the refresh token, not a long access token.
    Format like "30m", "1h". Only used when var.enable_mcp_saas_oidc is true.
  EOT
  type        = string
  default     = "30m"
}

variable "mcp_oidc_refresh_token_lifetime" {
  description = <<-EOT
    Refresh-token lifetime for the MCP SaaS-OIDC app (ADR-0005). This is the durable,
    revocable credential that lets clients silently refresh without a new login prompt —
    the direct lever for "stop re-auth prompts." Format like "720h" (30 days). Only used
    when var.enable_mcp_saas_oidc is true.
  EOT
  type        = string
  default     = "720h"
}

variable "family_emails" {
  description = "Allowlisted Google account emails that may reach Actual via Cloudflare Access."
  type        = list(string)
}

variable "admin_ssh_public_key" {
  description = "Your SSH public key, for root login to the VPS."
  type        = string
}

variable "admin_ip_cidr" {
  description = "Your home/office IP in CIDR form (e.g. 203.0.113.4/32) — SSH is locked to this (when ssh_over_tailscale_only is false)."
  type        = string
}

variable "ssh_over_tailscale_only" {
  description = <<-EOT
    When true, DROP the public SSH (tcp/22) firewall rule entirely — admin SSH is then
    reachable ONLY over the Tailscale tailnet (docs/install-tailscale.md), and an inbound
    udp/41641 rule is added so Tailscale can form a direct connection instead of relaying.
    When false (default), the original rule stands: tcp/22 open from var.admin_ip_cidr.

    ⚠️ Flip to true ONLY AFTER you have installed Tailscale on the box and confirmed you can
    SSH in over its 100.x tailnet address (install-tailscale.md §4). Applying this before
    Tailscale works locks you out of the public SSH path. var.admin_ip_cidr is still required
    either way (it's the SSH source when this is false, and your break-glass if you flip back).
  EOT
  type        = bool
  default     = false
}

variable "google_idp_name" {
  description = <<-EOT
    Name of the Google login method exactly as it appears in
    Zero Trust > Settings > Authentication (install doc step 2a). Used to look up
    the IdP for Access auto-redirect. Default "Google"; override if you reused an
    existing IdP that's named differently.
  EOT
  type        = string
  default     = "Google"
}

variable "access_session_duration" {
  description = <<-EOT
    How long a Cloudflare Access browser session lasts before Google re-login is required.
    Longer = less frequent re-auth, which keeps the web/PWA sync channel flowing (Actual is
    local-first, so offline editing is never blocked — only sync needs a live Access cookie);
    shorter = smaller window if a device is lost. "730h" = 1 month, "24h" = daily.
    Valid values include 30m, 6h, 12h, 24h, 168h (1 week), 730h (1 month).
  EOT
  type        = string
  default     = "730h"
}

# ---- Compute sizing -------------------------------------------------------

variable "server_type" {
  description = <<-EOT
    Hetzner server type. cpx21 (3 vCPU / 4GB AMD) for US locations; the cx* Intel
    line (e.g. cx22) is EU-only, so it can't be used with location = ash/hil.
  EOT
  type        = string
  default     = "cpx21"
}

variable "location" {
  description = "Hetzner location. ash = Ashburn/US-East, hil = Hillsboro/US-West, nbg1/fsn1/hel1 = EU, sin = Singapore."
  type        = string
  default     = "ash"
}

variable "volume_size_gb" {
  description = "Persistent data volume size in GB (Actual data + Hub SQLite live here)."
  type        = number
  default     = 20
}
