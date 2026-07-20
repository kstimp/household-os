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
    Cloudflare Access application AUD tag for the MCP host's self-hosted app (used with
    the optional service-token layer). NOTE: this is NOT the OIDC issuer path. The
    ADR-0003 idea of using this self-hosted app's JWT as the OIDC token failed (no
    OAuth token endpoint). The viable CF-issuer path (ADR-0005) is a separate CF Access
    *SaaS* (OIDC) application, whose own client ID is the `aud` — not this value. Empty
    unless var.enable_mcp_access_service_token is true.
  EOT
  value       = one(cloudflare_zero_trust_access_application.mcp[*].aud)
}

output "mcp_saas_oidc_client_id" {
  description = <<-EOT
    Client ID of the MCP SaaS-OIDC app (ADR-0005). This is ALSO the `aud` the MCP server
    validates: set it as OIDC_ACCEPTED_AUDIENCES in mcp.env (and, https://-prefixed, as
    OIDC_RESOURCE). Empty unless var.enable_mcp_saas_oidc is true.
  EOT
  value       = one(cloudflare_zero_trust_access_application.mcp_saas_oidc[*].saas_app[0].client_id)
}

output "mcp_saas_oidc_client_secret" {
  description = <<-EOT
    Client secret of the MCP SaaS-OIDC app (ADR-0005), for the AI-client connector config.
    Shown by Terraform; store it with the client. Empty unless var.enable_mcp_saas_oidc is
    true.
  EOT
  value       = one(cloudflare_zero_trust_access_application.mcp_saas_oidc[*].saas_app[0].client_secret)
  sensitive   = true
}

output "mcp_saas_oidc_issuer" {
  description = <<-EOT
    OIDC issuer to set as OIDC_ISSUER in mcp.env — your CF Zero Trust team domain,
    https://<team>.cloudflareaccess.com. Provider v4's saas_app block does not expose the
    team domain, so read it from Zero Trust → Settings → Custom Pages (team domain) and
    substitute it here; discovery, authorization/token endpoints, and JWKS all live under
    this issuer (same-origin JWKS → no OIDC_JWKS_TRUSTED_HOSTS). Empty unless
    var.enable_mcp_saas_oidc is true.
  EOT
  value       = var.enable_mcp_saas_oidc ? "https://<your-team>.cloudflareaccess.com" : ""
}

output "actual_api_url" {
  description = "Where the Actual HTTP REST API will live once deployed."
  value       = "https://${local.actual_api_host}"
}

output "actual_api_host" {
  description = "Public hostname for the Actual HTTP API. Used to fill the Caddyfile placeholder."
  value       = local.actual_api_host
}

output "actual_api_origin_cert_pem" {
  description = "Cloudflare Origin certificate for the Actual API host — write to certs/actual-api-origin.pem on the box."
  value       = cloudflare_origin_ca_certificate.actual_api.certificate
  sensitive   = true
}

output "actual_api_origin_key_pem" {
  description = "Origin private key for the Actual API host — write to certs/actual-api-origin.key on the box (chmod 600)."
  value       = tls_private_key.actual_api_origin.private_key_pem
  sensitive   = true
}

output "r2_bucket" {
  description = "Backup bucket name for Litestream + weekly Actual exports."
  value       = cloudflare_r2_bucket.backups.name
}

output "college_url" {
  description = "Where the College Fund App will live once Caddy + the container are up."
  value       = "https://${local.college_host}"
}

output "college_host" {
  description = "Public hostname College Fund is served at. Used to fill the Caddyfile placeholder."
  value       = local.college_host
}

output "college_origin_cert_pem" {
  description = "Cloudflare Origin certificate for college host — write to certs/college-origin.pem on the box."
  value       = cloudflare_origin_ca_certificate.college.certificate
  sensitive   = true
}

output "college_origin_key_pem" {
  description = "Origin private key for college host — write to certs/college-origin.key on the box (chmod 600)."
  value       = tls_private_key.college_origin.private_key_pem
  sensitive   = true
}

