output "server_ipv4" {
  description = "Public IPv4 of the VPS. SSH here and point your DNS sanity-checks at it."
  value       = hcloud_server.hub.ipv4_address
}

output "budget_url" {
  description = "Where Actual will live once Caddy + the container are up."
  value       = "https://${local.budget_host}"
}

output "budget_host" {
  description = "Public hostname Actual is served at (e.g. budget.yourdomain.com). Used to fill the Caddyfile placeholder."
  value       = local.budget_host
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

output "mcp_url" {
  description = "Where the MCP budget server endpoint will live (append the MCP path, default /http)."
  value       = "https://${local.mcp_host}"
}

output "mcp_host" {
  description = "Public hostname the MCP server is served at. Used to fill the Caddyfile mcp placeholder."
  value       = local.mcp_host
}

output "mcp_origin_cert_pem" {
  description = "Cloudflare Origin certificate for the MCP host — write to certs/mcp-origin.pem on the box."
  value       = cloudflare_origin_ca_certificate.mcp.certificate
  sensitive   = true
}

output "mcp_origin_key_pem" {
  description = "Origin private key for the MCP host — write to certs/mcp-origin.key on the box (chmod 600)."
  value       = tls_private_key.mcp_origin.private_key_pem
  sensitive   = true
}

output "mcp_access_service_token_client_id" {
  description = <<-EOT
    Cloudflare Access service-token Client ID for the MCP host. Empty unless
    var.enable_mcp_access_service_token is true (ADR-0003 interim layer). The MCP
    client sends this as the CF-Access-Client-Id header.
  EOT
  value       = one(cloudflare_zero_trust_access_service_token.mcp[*].client_id)
}

output "mcp_access_service_token_secret" {
  description = <<-EOT
    Cloudflare Access service-token Client Secret for the MCP host (CF-Access-Client-Secret
    header). Shown only on create/rotate; store it with the client. Empty unless
    var.enable_mcp_access_service_token is true.
  EOT
  value       = one(cloudflare_zero_trust_access_service_token.mcp[*].client_secret)
  sensitive   = true
}

output "mcp_access_application_aud" {
  description = <<-EOT
    Cloudflare Access application AUD tag for the MCP host (the `aud` claim in CF-issued
    JWTs). Use this as OIDC_RESOURCE in mcp.env when AUTH_PROVIDER=oidc and
    OIDC_ISSUER=https://<team>.cloudflareaccess.com. Empty unless
    var.enable_mcp_access_service_token is true.
  EOT
  value       = one(cloudflare_zero_trust_access_application.mcp[*].aud)
}

output "r2_bucket" {
  description = "Backup bucket name for Litestream + weekly Actual exports."
  value       = cloudflare_r2_bucket.backups.name
}
