# transit-app.hcl — Rechte für eine App, die Transit als
# Encryption-as-a-Service nutzt (nur ver-/entschlüsseln, kein Key-Management).
#
#   bao policy write transit-app transit-app.hcl

path "transit/encrypt/orders" {
  capabilities = ["update"]
}

path "transit/decrypt/orders" {
  capabilities = ["update"]
}

# optional: auf neue Key-Version umschlüsseln (sieht den Klartext nie)
path "transit/rewrap/orders" {
  capabilities = ["update"]
}
