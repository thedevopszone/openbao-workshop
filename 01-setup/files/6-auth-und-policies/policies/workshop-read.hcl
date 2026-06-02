# workshop-read.hcl — Leserechte auf die Workshop-Secrets (KV v2).
# Beachte die data/-Zwischenebene bei KV v2 (siehe 5-secrets-cli.md).
#
#   bao policy write workshop-read workshop-read.hcl

path "kv/data/workshop/*" {
  capabilities = ["read", "list"]
}

# Versionen/Metadaten auflisten dürfen (für `bao kv list` und `kv metadata get`)
path "kv/metadata/workshop/*" {
  capabilities = ["read", "list"]
}
