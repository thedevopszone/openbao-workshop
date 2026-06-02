# OpenBao Workshop

Hands-on-Workshop zu **OpenBao** — vom ersten Container bis zum produktionsnahen Cluster mit Auto-Unseal, Zugriffskontrolle, dynamischen Secrets und Betrieb. Alle Kapitel sind deutschsprachig, mit Schritt-für-Schritt-Anleitungen, Spickzetteln und Hardening-Hinweisen.

## Kapitel (`01-setup/`)

Aufbauend gedacht — von oben nach unten durcharbeiten:

| # | Datei | Inhalt |
|---|-------|--------|
| 0 | [`0-setup-docker.md`](01-setup/0-setup-docker.md) | Docker installieren (Voraussetzung) |
| 1 | [`1-docker-single-node.md`](01-setup/1-docker-single-node.md) | Single Node in Docker: Dev-Mode & persistenter Server, Init/Unseal, DNS/TLS |
| 2 | [`2-docker-cluster.md`](01-setup/2-docker-cluster.md) | 3-Node-HA-Cluster mit Integrated Raft, Failover-Demo |
| 3 | [`3-kubernetes.md`](01-setup/3-kubernetes.md) | OpenBao auf k3d via Helm, Auto-Unseal (Transit), OpenTofu, Postgres + ESO |
| 4 | [`4-auto-unseal.md`](01-setup/4-auto-unseal.md) | Auto-Unseal per HSM (SoftHSMv2 / PKCS#11) |
| 5 | [`5-secrets-cli.md`](01-setup/5-secrets-cli.md) | CLI: Secrets Engines aktivieren, Secrets schreiben/lesen (KV v1/v2) |
| 6 | [`6-auth-und-policies.md`](01-setup/6-auth-und-policies.md) | Zugriff ohne Root: Auth-Methoden, Policies, Tokens, Audit |
| 7 | [`7-dynamic-secrets.md`](01-setup/7-dynamic-secrets.md) | Dynamische Secrets: Transit, DB-Credentials on demand, PKI |
| 8 | [`8-operations.md`](01-setup/8-operations.md) | Betrieb: Raft-Snapshots, Key-Rotation, Monitoring |
| 9 | [`9-agent-und-k8s-auth.md`](01-setup/9-agent-und-k8s-auth.md) | Kubernetes-Auth & OpenBao Agent: Secrets ohne statischen Token |
| 10 | [`10-secrets-in-pods.md`](01-setup/10-secrets-in-pods.md) | Secret-Delivery: Agent Injector, CSI Driver, ESO vs. VSO |
| 11 | [`11-pki-cert-manager.md`](01-setup/11-pki-cert-manager.md) | OpenBao-PKI als cert-manager-Issuer (interne mTLS-Zertifikate) |
| 12 | [`12-produktion-k8s.md`](01-setup/12-produktion-k8s.md) | Produktion in K8s: Hardening, Services, NetworkPolicy, Upgrades, ServiceMonitor |
| 13 | [`13-k8s-engine-und-dr.md`](01-setup/13-k8s-engine-und-dr.md) | kubernetes Secrets Engine (SA-Tokens) & Disaster Recovery (Restore) |

## Roter Faden

1. **Aufsetzen** (0–4): vom Dev-Container über HA-Cluster bis Auto-Unseal.
2. **Benutzen** (5–7): Secrets verwahren → Zugriff absichern → Secrets dynamisch erzeugen.
3. **Betreiben** (8): Backup, Rotation, Monitoring — und die Produktions-Checkliste.
4. **Integrieren** (9–11): Pods authentifizieren sich nativ; Secrets per Injector/CSI/Operator; Zertifikate aus der PKI.
5. **Produktiv & absichern** (12–13): K8s-Hardening/Upgrades/Monitoring, kubernetes-Engine und Disaster Recovery.

## Konfigurationsdateien

Fertige Beispiele liegen unter [`01-setup/files/`](01-setup/files/): Docker-Compose & HCL-Configs für Single-Node und Cluster, sowie für Kubernetes die Helm-Values, OpenTofu-Module (`terraform/`) und das Postgres-/ESO-Demo (`postgres/`).

## Voraussetzungen

- Docker mit Compose-Plugin
- Optional die `bao`-CLI auf dem Host (Installationshinweise in Kapitel 1)
- Für Kapitel 3: `k3d`, `kubectl`, `helm`, `tofu` (OpenTofu)
