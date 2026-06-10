locals {
  budget_host = "${var.budget_subdomain}.${var.domain}"
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
resource "hcloud_firewall" "hub" {
  name = "household-os-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip_cidr]
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

# Cloudflare Access: only allowlisted Google accounts reach Actual at all.
resource "cloudflare_zero_trust_access_application" "budget" {
  account_id                = var.cloudflare_account_id
  name                      = "Household OS — Budget (Actual)"
  domain                    = local.budget_host
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = true
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
# Backups: R2 bucket for Litestream (Hub SQLite) + weekly Actual exports.
# ---------------------------------------------------------------------------

resource "cloudflare_r2_bucket" "backups" {
  account_id = var.cloudflare_account_id
  name       = "household-os-backups"
  location   = "ENAM"
}
