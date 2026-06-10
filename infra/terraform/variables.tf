# ---- Provider credentials -------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Project > Security > API Tokens, Read & Write)."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token scoped to: Zone:DNS:Edit, Account:Access (Apps & Policies):Edit,
    Account:Cloudflare R2:Edit, Zone:SSL and Certificates:Edit (for the Origin cert).
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

# ---- Compute sizing -------------------------------------------------------

variable "server_type" {
  description = "Hetzner server type. cx22 (2 vCPU / 4GB) is plenty for Actual + headroom."
  type        = string
  default     = "cx22"
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ash, hil)."
  type        = string
  default     = "fsn1"
}

variable "volume_size_gb" {
  description = "Persistent data volume size in GB (Actual data + Hub SQLite live here)."
  type        = number
  default     = 20
}
