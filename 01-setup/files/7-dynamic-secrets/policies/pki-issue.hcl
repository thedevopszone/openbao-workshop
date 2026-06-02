# pki-issue.hcl — Eine App/ein Dienst darf Zertifikate über die Rolle "web"
# ausstellen (PKI aus 7-dynamic-secrets.md).
#
#   bao policy write pki-issue pki-issue.hcl

path "pki/issue/web" {
  capabilities = ["update"]
}
