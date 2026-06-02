# db-dynamic-read.hcl — Eine App darf frische, kurzlebige DB-Credentials
# anfordern (Dynamic Role aus 7-dynamic-secrets.md).
#
#   bao policy write db-dynamic-read db-dynamic-read.hcl

path "database/creds/app-dynamic" {
  capabilities = ["read"]
}
