terraform {
  required_version = ">= 1.6"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      # NOTE: Cloudflare provider resource names drift between majors.
      # This config targets v4.40+. If you bump to v5, several resources
      # are renamed (e.g. cloudflare_record -> cloudflare_dns_record,
      # cloudflare_zero_trust_access_* keep their names). Run
      # `terraform validate` after any provider upgrade.
      version = "~> 4.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Recommended: keep state off your laptop once this is real.
  # backend "s3" {}  # R2 is S3-compatible; wire this up after first apply.
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
