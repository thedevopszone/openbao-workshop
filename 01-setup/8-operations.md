# Betrieb (Day-2) — Backup, Key-Rotation, Monitoring

**Summary**:

Was nach dem Aufsetzen kommt: **Raft-Snapshots** (Backup & Restore — der Datenrettungsanker), **Schlüssel drehen** (`operator rekey` für die Unseal-/Recovery-Shares, `operator rotate` für den Encryption-Key) und **Monitoring** per Prometheus-Telemetry plus Health-Endpoints. Voraussetzung: ein laufender Cluster mit **Integrated Raft** (siehe `2-docker-cluster.md` / `3-kubernetes.md`), Admin-Login.

---

## Worum es hier geht

Die bisherigen Kapitel haben OpenBao aufgesetzt und benutzt. Im echten Betrieb entscheidet etwas anderes über Erfolg oder Datenverlust:


| Aufgabe        | Frage                                 | Befehl                      |
| -------------- | ------------------------------------- | --------------------------- |
| **Backup**     | Wie hole ich alles zurück nach Crash? | `operator raft snapshot`    |
| **Rekey**      | Unseal-Keys neu verteilen/widerrufen  | `operator rekey`            |
| **Rotate**     | Encryption-Key turnusmäßig wechseln   | `operator rotate`           |
| **Monitoring** | Läuft er? Wird er voll?               | `sys/health`, `sys/metrics` |


> Diese Dinge übt man **vor** dem Ernstfall. Ein Backup, das man nie zurückgespielt hat, ist kein Backup.

---

## Teil 1 — Raft-Snapshots (Backup & Restore)

Bei **Integrated Raft** liegen alle Daten (Secrets, Policies, Auth-Konfig, Mounts) im Raft-Store. Ein **Snapshot** ist eine konsistente Komplettkopie — gezogen vom Leader, im laufenden Betrieb.

### Snapshot ziehen

```bash
# erzeugt eine binäre, konsistente Sicherung
bao operator raft snapshot save bao-$(date +%F).snap
```

Im Docker-/k8s-Kontext aus dem Container heraus und herauskopieren. **Snapshot/Restore brauchen einen privilegierten Token** — innerhalb des Containers/Pods ist normalerweise keiner gesetzt, also entweder vorher dort `bao login` ausführen (cached in `~/.vault-token`) **oder** `VAULT_TOKEN` direkt mitgeben (sonst `permission denied`):

```bash
# Docker Compose (Cluster aus 2-docker-cluster.md)
# Variante a) vorher einmal im Container einloggen: docker compose exec -it bao-1 bao login
docker compose exec bao-1 sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao operator raft snapshot save /tmp/bao.snap'
docker compose cp bao-1:/tmp/bao.snap ./bao.snap

# Kubernetes (Token explizit mitgeben)
kubectl -n openbao exec openbao-0 -- sh -c 'VAULT_TOKEN=<root-token> bao operator raft snapshot save /tmp/bao.snap'
kubectl -n openbao cp openbao-0:/tmp/bao.snap ./bao.snap
```

> **Der Snapshot enthält die verschlüsselten Daten — nicht die Unseal-/Recovery-Keys.** Zum Restore brauchst du **weiterhin die Keys** des Ziel-Clusters. Snapshot + Keys getrennt aufbewahren; den Snapshot trotzdem als sensibel behandeln.

### Snapshot zurückspielen

```bash
bao operator raft snapshot restore bao.snap
```

Der Restore **überschreibt den kompletten Zustand** des Clusters mit dem Snapshot. Danach ist der Cluster im Zustand des Backup-Zeitpunkts.

> **Wichtig zum Verständnis:** Der Restore behält den **Barrier-/Master-Key des Snapshots** bei. Spielst du in einen *frischen* Cluster zurück, musst du mit den **Unseal-Keys von damals** (zum Snapshot passend) unsealen, nicht mit denen des neuen Clusters. Deshalb: Snapshot **und** zugehörige Keys zusammen denken.

### Übung für den Workshop

1. Secret schreiben: `bao kv put kv/workshop/backup-test wert=vorher`
2. Snapshot ziehen (s. o.).
3. Secret „kaputt machen": `bao kv put kv/workshop/backup-test wert=ups`
4. Restore → prüfen, dass wieder `vorher` dasteht.

Das ist der überzeugendste Teil: einmal real zurückgespielt zu haben.

> **Automatisieren:** In Produktion läuft das als Cronjob (z. B. stündlich) mit Versionierung und Off-Site-Kopie. OpenBao-Enterprise/Vault kennen auto-snapshots; in der OSS-CLI nimmt man einen externen Scheduler.

---

## Teil 2 — Schlüssel drehen: Rekey vs. Rotate

Zwei verschiedene Schlüssel, zwei verschiedene Operationen — werden oft verwechselt:


|               | **Rekey** (`operator rekey`)                            | **Rotate** (`operator rotate`)    |
| ------------- | ------------------------------------------------------- | --------------------------------- |
| betrifft      | **Unseal-/Recovery-Key-Shares**                         | den **Encryption-Key** (Barrier)  |
| wann          | Person scheidet aus, Key-Verdacht, Anzahl Shares ändern | turnusmäßige Hygiene, Compliance  |
| sichtbar      | neue Shares werden ausgegeben                           | unsichtbar, kein Neu-Unseal nötig |
| Unterbrechung | nein (Server läuft weiter)                              | nein                              |


### Rotate — den Encryption-Key wechseln

Der einfache Fall. OpenBao fügt eine **neue Key-Version** hinzu; neue Schreibvorgänge nutzen sie, alte Daten bleiben lesbar. Kein erneutes Unseal nötig.

```bash
bao operator rotate
bao operator key-status   # zeigt aktuelle Key-Version + Installationszeit
```

> Risikoarm und jederzeit machbar — guter Kandidat für einen regelmäßigen Job.

### Rekey — die Unseal-Shares neu ausgeben

Aufwendiger, weil es die **Shamir-Shares** neu erzeugt (z. B. um einen kompromittierten Share zu entwerten oder die Aufteilung zu ändern). Erfordert die **aktuellen** Keys, um die Operation zu autorisieren:

```bash
# Rekey starten: künftig 5 Shares, Threshold 3
bao operator rekey -init -key-shares=5 -key-threshold=3

# mit den AKTUELLEN Unseal-Keys bestätigen (Threshold-mal)
bao operator rekey   # alten Key 1 eingeben
bao operator rekey   # alten Key 2 eingeben
bao operator rekey   # alten Key 3 eingeben
# -> gibt die NEUEN Shares aus (einmalig!)
```

#### Empfohlener Weg: authentifiziertes Rotate

Du brauchst einen Token mit `sudo` auf `sys/rotate/root` (ein Root-Token reicht). Dann statt `bao operator rekey`:

```bash
# 1. Rotation initialisieren -> liefert einen nonce
bao write -f sys/rotate/root/init secret_shares=5 secret_threshold=3

# 2. Jeder Key-Holder reicht seine bestehende Unseal-Share ein (3x, bis Threshold erreicht)
bao write sys/rotate/root/update key=<unseal-key-share> nonce=<nonce-aus-init>
```

Nach der dritten Share ist `complete: true` und du bekommst die neuen Shares (`keys_base64`).

Falls `bao write` bei dir aus irgendeinem Grund zickt, geht es identisch per curl (Token nicht vergessen — anders als beim alten unauthed-Pfad ist er jetzt Pflicht):

```bash
curl -s --request POST \
  --header "X-Vault-Token: $BAO_TOKEN" \
  --data '{"secret_shares":5,"secret_threshold":3}' \
  https://openbao.intern.devopsdns.com/v1/sys/rotate/root/init
```

Status / Abbruch analog über GET bzw. DELETE auf `sys/rotate/root/init`.

> **Auto-Unseal (HSM/Transit):** Dort gibt es keine Shamir-Unseal-Keys, sondern **Recovery Keys** (siehe `4-auto-unseal.md`). Die werden mit `bao operator rekey -target=recovery -init ...` neu ausgegeben — analoger Ablauf, anderes Ziel.

> Die neuen Shares erscheinen **genau einmal** — gleiche Sorgfalt wie bei der Init-Ausgabe (`1-docker-single-node.md`).

---

## Teil 3 — Root-Token weg: `generate-root`

Den Root-Token nach dem Setup zu widerrufen (`bao token revoke -self`) ist **Best Practice** (siehe Checkliste unten). Aber was, wenn man ihn später wieder braucht — etwa weil keine andere Auth-Methode mehr `sudo`-Rechte hat? Dafür gibt es `bao operator generate-root`: Ein **Quorum der Unseal-Key-Holder** (bei uns 3 von 5) autorisiert gemeinsam die Erzeugung eines neuen Root-Tokens.

### Stolperfalle: ab OpenBao 2.5.3 deaktiviert

Seit **OpenBao 2.5.3** sind die unauthentifizierten `sys/generate-root/*`-Endpoints **standardmäßig abgeschaltet** (deprecated). Der Aufruf scheitert dann mit:

```
Code: 405. Errors:
* unsupported operation
```

Der empfohlene Ersatz ist `bao token create` mit einem existierenden `sudo`-Token — der hilft aber genau dann nicht, wenn gar kein Token mehr da ist. Für diesen Notfall lässt sich der alte Weg per Listener-Parameter **temporär** reaktivieren. In `files/3-kubernetes/values-ingress.yml`:

```hcl
listener "tcp" {
  tls_disable     = 1
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  # TEMPORÄR: generate-root reaktivieren (seit OpenBao 2.5.3 default deaktiviert)
  # Nach der Root-Token-Generierung wieder entfernen!
  disable_unauthed_generate_root_endpoints = false
}
```

Listener-Parameter werden **nicht** per SIGHUP nachgeladen — es braucht ein `helm upgrade` plus Pod-Neustart, und nach dem Neustart heißt es bei Shamir: **jeden Pod neu unsealen**.

```bash
helm upgrade openbao openbao/openbao -n openbao --version 0.28.3 -f values-ingress.yml
kubectl delete pod -n openbao openbao-0 openbao-1 openbao-2

# je Pod 3x unsealen (openbao-1/-2 starten erst, wenn der Vorgänger ready ist)
kubectl exec -n openbao openbao-0 -- bao operator unseal <key-share>
```

### Die eigentliche Prozedur

```bash
# 1. Vorgang starten -> merkt euch OTP und Nonce!
bao operator generate-root -init

# 2. Threshold-mal eine Unseal-Share einreichen (Progress 3/3 -> Encoded Token)
bao operator generate-root   # Key 1
bao operator generate-root   # Key 2
bao operator generate-root   # Key 3

# 3. Encoded Token mit dem OTP aus Schritt 1 entschlüsseln -> neuer Root-Token
bao operator generate-root -decode=<encoded-token> -otp=<otp>

bao login <neuer-root-token>
```

Status prüfen bzw. abbrechen geht jederzeit mit `-status` / `-cancel`. In einem echten Multi-Holder-Setup reicht jeder Key-Holder seine Share auf der eigenen Maschine mit `-nonce=<nonce>` ein.

> **Auto-Unseal (HSM/Transit):** Statt Unseal-Keys werden die **Recovery Keys** eingereicht (siehe `4-auto-unseal.md`) — der Ablauf ist identisch.

### Danach: aufräumen und vorsorgen

1. **Parameter wieder entfernen** (`disable_unauthed_generate_root_endpoints`-Zeile löschen, `helm upgrade`, Neustart, Unseal) — der Endpoint ist unauthentifiziert erreichbar und soll nicht dauerhaft offen sein.
2. **Break-Glass-Token anlegen**, damit der nächste Notfall ohne diese Prozedur auskommt:

```bash
bao token create -policy=root -no-default-policy -display-name=break-glass
```

Den Token **offline und getrennt von den Unseal-Keys** verwahren. Das ist der von OpenBao empfohlene Weg: neuer Root-Token aus bestehendem `sudo`-Token statt `generate-root`.

---


## Teil 4 — Monitoring & Health

### Health-Endpoints (kein Token nötig)

Ideal für Load-Balancer und Probes:

```bash
curl -s http://127.0.0.1:8200/v1/sys/health | jq

# oder
curl -s https://openbao.intern.devopsdns.com/v1/sys/health | jq

```

Der **HTTP-Statuscode** kodiert den Zustand (extern verifiziert: `openbao.org/api-docs/system/health`):


| Code | Bedeutung                                       |
| ---- | ----------------------------------------------- |
| 200  | initialisiert, **unsealed**, **aktiv** (Leader) |
| 429  | unsealed, aber **Standby**                      |
| 472  | im Disaster-Recovery-Modus                      |
| 501  | **nicht initialisiert**                         |
| 503  | **sealed**                                      |


In Kubernetes nutzt der Helm-Chart genau das für Readiness/Liveness; gut zu wissen, dass „429" bei Standby-Pods **normal** ist und kein Fehler.

### Prometheus-Telemetry

Telemetry in der Server-Config aktivieren:

```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}
```

Danach scrapebar (Token mit `read` auf `sys/metrics` nötig):

```bash
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "http://127.0.0.1:8200/v1/sys/metrics?format=prometheus"
```

Sinnvolle Metriken im Auge behalten:

- `vault.core.unsealed` — 1 = unsealed (Alarm bei 0!).
- `vault.raft.leader.lastContact` / `vault_raft_storage_*` — Raft-Gesundheit, Leader-Kontakt.
- `vault.token.count`, `vault.expire.num_leases` — Token-/Lease-Wachstum (Leak-Indikator).
- `vault.runtime.alloc_bytes`, `vault.barrier.*` — Last/Latenz.

> **Audit ist die andere Hälfte des Monitorings** (siehe `6-auth-und-policies.md`): Metriken sagen *wie viel*, das Audit-Log sagt *wer was*.

---

## Spickzettel

```bash
# Backup / Restore (Raft)
bao operator raft snapshot save  bao.snap
bao operator raft snapshot restore bao.snap
bao operator raft list-peers              # Cluster-Mitglieder
bao operator raft autopilot state         # Health / Failure Tolerance

# Key-Rotation
bao operator rotate                       # Encryption-Key, risikoarm
bao operator key-status
bao operator rekey -init -key-shares=5 -key-threshold=3   # Unseal-Shares neu
bao operator rekey                        # Threshold-mal mit alten Keys bestätigen

# Health / Metrics
curl -s http://127.0.0.1:8200/v1/sys/health | jq
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "http://127.0.0.1:8200/v1/sys/metrics?format=prometheus"
```

> Fertige Dateien: `files/8-operations/` — `snapshot.sh` (Backup mit Rotation, direkt oder via Docker), `snapshot-cronjob.yaml` (stündliches Backup in k8s) und `telemetry.hcl` (Prometheus-Config).

---

## Checkliste „produktionsbereit"

Sammelt die verstreuten Hardening-Hinweise der vorigen Kapitel:

- **Auto-Unseal** statt manuellem Shamir (`3-kubernetes.md` Transit / `4-auto-unseal.md` HSM)
- **TLS** überall an, kein `tls_disable` (`1-docker-single-node.md`)
- **Integrated Raft**, ≥ 3 (besser 5) Nodes über getrennte Failure-Domains (`2-docker-cluster.md`)
- **Root-Token widerrufen**, Zugriff über Auth-Methoden + Policies (`6-auth-und-policies.md`)
- **2 Audit-Devices** aktiv (`6-auth-und-policies.md`)
- **Snapshots** automatisiert + Restore **getestet** (dieses Kapitel)
- **Key-Rotation** als Routine eingeplant
- **Monitoring**: `sys/health`-Probes + Prometheus-Scrape + Alarm auf `vault.core.unsealed == 0`
- **mlock**/Swap behandelt (`1-docker-single-node.md`)

