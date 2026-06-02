# OpenBao in Kubernetes produktiv betreiben

**Summary**:

Was das Workshop-Helm-Deployment aus `3-kubernetes.md` für den echten Betrieb braucht: **Hardening** der Helm-Werte (resources, PodDisruptionBudget, securityContext, Probes, StorageClass, Anti-Affinity), **Upgrades** ohne Downtime (StatefulSet rollend, Standbys zuerst), die **Services** des Charts verstehen, **NetworkPolicy** und **Monitoring** per Prometheus-Operator. Voraussetzung: laufender HA-Cluster mit Auto-Unseal (`3-kubernetes.md` Teil 4) und die Betriebs-Grundlagen aus `8-operations.md`.

---

## 1. Helm-Werte härten

Das Workshop-`values` ist minimal. Eine produktionsnähere Fassung:

```yaml
server:
  ha:
    enabled: true
    replicas: 3                    # produktiv eher 5 (Failure Tolerance 2)

  # Ressourcen festnageln (sonst kann der Scheduler/OOM-Killer zuschlagen)
  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { memory: 512Mi }    # KEIN CPU-Limit (Throttling vermeiden)

  # PodDisruptionBudget: bei Node-Drains nie das Quorum verlieren
  # (das Chart erzeugt es; maxUnavailable=1 ist Default für 3 Replicas)

  # nicht als root laufen
  statefulSet:
    securityContext:
      pod:       { runAsNonRoot: true, runAsUser: 100, fsGroup: 1000 }
      container: { allowPrivilegeEscalation: false }

  # eine Replica pro Node erzwingen (Default-Anti-Affinity des Charts)
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ template "openbao.name" . }}
              app.kubernetes.io/instance: "{{ .Release.Name }}"
              component: server
          topologyKey: kubernetes.io/hostname

  # persistenter Raft-Storage: Größe + Klasse explizit
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: null             # produktiv eine echte, replizierte StorageClass

  # Readiness/Liveness nutzen sys/health (siehe unten)
  readinessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"

  priorityClassName: system-cluster-critical
```

> **Warum kein CPU-Limit?** OpenBao ist latenzkritisch; ein CPU-Limit führt zu Throttling unter Last. Memory-Limit dagegen sinnvoll. (Faustregel aus den meisten Vault/OpenBao-Reference-Setups.)

### Probes verstehen — die `sys/health`-Codes

Der `readinessProbe`-Pfad oben kodiert den HA-Zustand über **HTTP-Statuscodes** (vgl. `8-operations.md`):

- `standbyok=true` → Standby-Pods (sonst 429) gelten trotzdem als „ok", damit sie `Ready` werden.
- `sealedcode=204`, `uninitcode=204` → sealed/uninitialized liefern **204** statt 503/501, je nach gewünschtem Ready-Verhalten beim Bootstrap.

Ohne diese Parameter würden frisch gestartete (noch sealed) Pods nie ready — gerade beim manuellen Unseal aus Teil 2 wichtig zu wissen.

---

## 2. Die Services des Charts

Das Chart legt mehrere Services an — wer sie verwechselt, jagt Phantom-Fehler:

| Service | Zeigt auf | Wofür |
| ------------------- | ----------------------- | ------------------------------------------ |
| `openbao` | alle Pods (auch Standby) | generischer Zugriff (Standby leitet weiter) |
| `openbao-active` | **nur den Leader** | Schreibzugriff ohne Redirect (z. B. OpenTofu) |
| `openbao-standby` | nur Standbys | Read-Only-Lastverteilung (selten gebraucht) |
| `openbao-internal` | alle Pods (**headless**) | Raft node-to-node (`retry_join`, Port 8201) |
| `openbao-ui` | alle Pods | die Web-UI |

> Genau deshalb steht im OpenTofu-Teil (`3-kubernetes.md`) `port-forward svc/openbao-active` — Schreibvorgänge sollen direkt zum Leader. Der **headless** `openbao-internal` ist die Basis für die `retry_join`-Adressen (`openbao-0.openbao-internal:8200`).

---

## 3. NetworkPolicy

Standardmäßig ist im Cluster alles offen. OpenBao gehört abgeriegelt — nur App-Namespaces dürfen die API, nur die Pods untereinander den Cluster-Port:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openbao
  namespace: openbao
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: openbao }
  policyTypes: [Ingress]
  ingress:
    # API (8200) nur aus erlaubten App-Namespaces
    - from:
        - namespaceSelector:
            matchLabels: { openbao-access: "true" }
      ports:
        - { protocol: TCP, port: 8200 }
    # Cluster-Port (8201) nur zwischen OpenBao-Pods selbst
    - from:
        - podSelector:
            matchLabels: { app.kubernetes.io/name: openbao }
      ports:
        - { protocol: TCP, port: 8201 }
```

> Namespaces, die zugreifen dürfen, mit `kubectl label ns <app-ns> openbao-access=true` markieren. NetworkPolicies wirken nur, wenn die CNI sie umsetzt (k3d/Flannel: eingeschränkt — produktiv Calico/Cilium).

---

## 4. Upgrades ohne Downtime

OpenBao im StatefulSet wird **rollend** aktualisiert — die Reihenfolge ist entscheidend, damit das Quorum nie bricht:

```bash
helm repo update
helm upgrade openbao openbao/openbao -n openbao --reuse-values \
  --set server.image.tag=<neue-version>

# Reihenfolge: STANDBYS zuerst, der AKTIVE Leader ZULETZT.
# Bei Auto-Unseal kommen die Pods von selbst entsiegelt zurück (Teil 4);
# bei Shamir muss jeder neue Pod manuell unsealed werden.
kubectl -n openbao rollout status statefulset/openbao
kubectl -n openbao exec openbao-0 -- bao operator raft autopilot state
```

> **Standby-first:** Aktualisiert man den Leader zuerst, gibt es eine unnötige Leader-Wahl mitten im Upgrade. Manche Charts setzen `updateStrategy: OnDelete` — dann löscht man die Pods bewusst in der richtigen Reihenfolge (`openbao-2`, `-1`, zuletzt der aktive). Nach jedem Pod: `autopilot state` → `Healthy: true` abwarten, erst dann den nächsten.

> **Vor jedem Upgrade:** Snapshot ziehen (`8-operations.md`). Versionssprünge nicht überspringen; Release Notes auf Storage-/Migrations-Hinweise prüfen.

---

## 5. Monitoring per Prometheus-Operator

`8-operations.md` zeigt den rohen Scrape. In K8s mit Prometheus-Operator stattdessen ein **ServiceMonitor** — plus Telemetry-Config und Metrik-Zugriff:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: openbao
  namespace: openbao
  labels: { release: prometheus }   # zum Prometheus-Selector passend
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: openbao }
  endpoints:
    - port: http
      path: /v1/sys/metrics
      params: { format: ["prometheus"] }
      interval: 30s
```

Dazu in der Server-Config (Helm `server.ha.raft.config`) die Telemetry aktivieren und den Metrik-Endpunkt erreichbar machen:

```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}

listener "tcp" {
  # ... bestehende Felder ...
  telemetry { unauthenticated_metrics_access = true }   # nur hinter NetworkPolicy!
}
```

Alarme (vgl. `8-operations.md`): `vault.core.unsealed == 0`, Leader-Wechsel-Rate, `vault.expire.num_leases`-Wachstum.

---

## Checkliste „K8s-produktiv"

- [ ] **Auto-Unseal** aktiv (Transit/KMS/HSM) — `3-kubernetes.md`, `4-auto-unseal.md`
- [ ] `resources` gesetzt (Memory-Limit, kein CPU-Limit), `priorityClassName`
- [ ] **PodDisruptionBudget** + **Anti-Affinity** über getrennte Nodes/Zonen
- [ ] `securityContext` (runAsNonRoot), `dataStorage` mit echter StorageClass
- [ ] **NetworkPolicy** vor der API; CNI setzt sie um (Calico/Cilium)
- [ ] **TLS** am Listener oder mindestens am Ingress (`3-kubernetes.md`, `11-pki-cert-manager.md`)
- [ ] **Snapshots** automatisiert + Restore getestet (`8-operations.md`, `13-k8s-engine-und-dr.md`)
- [ ] **ServiceMonitor** + Alarm auf `vault.core.unsealed == 0`
- [ ] **Upgrade-Runbook**: Snapshot → Standbys zuerst → autopilot prüfen → Leader zuletzt

> Fertige Dateien: `files/12-produktion-k8s/` — `values-production.yaml`, `networkpolicy.yaml` und `servicemonitor.yaml`.

---

## Roter Faden

1. `3-kubernetes.md` — das (Workshop-)Deployment.
2. `8-operations.md` — Snapshots, Rotation, Monitoring-Grundlagen.
3. **Dieses Kapitel** — dasselbe Deployment produktionsfest: Hardening, Services, NetworkPolicy, Upgrades, ServiceMonitor.
