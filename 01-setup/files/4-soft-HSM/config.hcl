ui = true
disable_mlock = true

storage "file" {
  path = "/opt/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"          # NUR lokaler Test
}

# Auto-Unseal über das HSM (SoftHSMv2 via PKCS#11).
# rsa_oaep_hash = "sha1", weil SoftHSMv2 RSA-OAEP mit SHA-256 ablehnt
# (echtes HSM kann i. d. R. sha256). Siehe 4-auto-unseal.md.
seal "pkcs11" {
  lib           = "/usr/lib/softhsm/libsofthsm2.so"
  token_label   = "OpenBao"
  pin           = "4321"
  key_label     = "bao-root-key-rsa"
  mechanism     = "RSA_PKCS_OAEP"
  rsa_oaep_hash = "sha1"
}

api_addr = "http://127.0.0.1:8200"
