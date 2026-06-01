ui = true

storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # NUR für lokalen Test — siehe Abschnitt DNS/TLS
}

api_addr = "http://127.0.0.1:8200"
