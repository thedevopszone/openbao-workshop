terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Adresse & Token kommen aus VAULT_ADDR / VAULT_TOKEN (oben exportiert)
provider "vault" {}

# 1) KV-v2-Secrets-Engine unter "kv/"
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv-v2"
  description = "Workshop KV store"
}

# 2) Policy: Leserechte auf kv/data/workshop/*
resource "vault_policy" "workshop_read" {
  name   = "workshop-read"
  policy = <<-EOT
    path "kv/data/workshop/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

# 3) userpass-Auth-Methode
resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

# 4) Benutzer "workshop" mit der Policy oben
resource "vault_generic_endpoint" "workshop_user" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/workshop"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "workshop123"
    policies = ["workshop-read"]
  })
}

# 5) ein Beispiel-Secret
resource "vault_kv_secret_v2" "demo" {
  mount = vault_mount.kv.path
  name  = "workshop/hello"
  data_json = jsonencode({
    message = "OpenBao Workshop läuft!"
  })
}