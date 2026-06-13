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

# ---- Access control -------------------------------------------------------

variable "family_emails" {
  description = "Allowlisted Google account emails that may reach Actual via Cloudflare Access."
  type        = list(string)
}

variable "admin_ssh_public_key" {
  description = "Your SSH public key, for root login to the VPS."
  type        = string
}

variable "admin_ip_cidr" {
  description = "Your home/office IP in CIDR form (e.g. 203.0.113.4/32) — SSH is locked to this."
  type        = string
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
