output "server_ipv4" {
  description = "Public IPv4 of the VPS. SSH here and point your DNS sanity-checks at it."
  value       = hcloud_server.hub.ipv4_address
}

output "budget_url" {
  description = "Where Actual will live once Caddy + the container are up."
  value       = "https://${local.budget_host}"
}

output "origin_cert_pem" {
  description = "Cloudflare Origin certificate — write to infra/actual/certs/origin.pem on the box."
  value       = cloudflare_origin_ca_certificate.budget.certificate
  sensitive   = true
}

output "origin_key_pem" {
  description = "Origin private key — write to infra/actual/certs/origin.key on the box (chmod 600)."
  value       = tls_private_key.origin.private_key_pem
  sensitive   = true
}

output "r2_bucket" {
  description = "Backup bucket name for Litestream + weekly Actual exports."
  value       = cloudflare_r2_bucket.backups.name
}
