# workshop-write.hcl — Voller Lese-/Schreibzugriff auf die Workshop-Secrets
# inkl. löschen und endgültig vernichten (KV v2 — Pfad-Ebenen beachten).
#
#   bao policy write workshop-write workshop-write.hcl

# Secret lesen/anlegen/ändern
path "kv/data/workshop/*" {
  capabilities = ["create", "update", "read", "list"]
}

# Soft-Delete einzelner Versionen
path "kv/delete/workshop/*" {
  capabilities = ["update"]
}

# Undelete (Soft-Delete rückgängig)
path "kv/undelete/workshop/*" {
  capabilities = ["update"]
}

# Versionen endgültig vernichten
path "kv/destroy/workshop/*" {
  capabilities = ["update"]
}

# Metadaten/Versionen verwalten + auflisten
path "kv/metadata/workshop/*" {
  capabilities = ["create", "update", "read", "list", "delete"]
}
