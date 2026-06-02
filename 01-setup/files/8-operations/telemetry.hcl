# telemetry.hcl — Prometheus-Telemetry für OpenBao aktivieren.
# In das Config-Verzeichnis legen (z. B. neben config.hcl), wird beim
# Start mitgelesen (siehe 1-docker-single-node.md, Variante B).
#
# Danach scrapebar unter:
#   GET /v1/sys/metrics?format=prometheus   (Token mit read auf sys/metrics)

telemetry {
  # Metriken im Speicher vorhalten, damit der Scrape sie findet
  prometheus_retention_time = "24h"

  # Hostname nicht an jeden Metriknamen hängen (sonst zerfasern die Serien)
  disable_hostname = true
}

# Optionaler unauthentifizierter Metrik-Endpunkt am Listener.
# Vorsicht: gibt Betriebskennzahlen ohne Token preis — nur in
# abgeschotteten Netzen / hinter dem Scrape-Proxy verwenden.
#
# listener "tcp" {
#   address                  = "0.0.0.0:8200"
#   tls_disable              = true
#   telemetry {
#     unauthenticated_metrics_access = true
#   }
# }
