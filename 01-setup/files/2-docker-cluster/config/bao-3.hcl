ui = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "bao-3"

  # Node 2 und 3 brauchen das nicht zwingend (sie joinen),
  # aber retry_join auf ALLEN Nodes macht Neustarts robust:
  retry_join { leader_api_addr = "http://bao-1:8200" }
  retry_join { leader_api_addr = "http://bao-2:8200" }
  retry_join { leader_api_addr = "http://bao-3:8200" }
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"          # NUR lokaler Test — produktiv TLS, siehe [[docker]]
}

# Pflicht bei Raft: wo sprechen die Nodes miteinander.
# https, weil der Cluster-Port IMMER mTLS nutzt (auch bei tls_disable am API-Port).
cluster_addr = "https://bao-3:8201"

# Adresse, unter der dieser Node von Clients/Peers erreichbar ist (landet in Redirects).
api_addr     = "http://bao-3:8200"