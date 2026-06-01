# OpenBao-Cluster mit Docker Compose

**Summary**: Wie man lokal einen 3-Node-OpenBao-Cluster mit Docker Compose und Integrated [[raft|Raft]]-Storage aufsetzt — drei Container, einer initialisiert den Cluster, die anderen beiden joinen per `retry_join` (oder CLI), jeder Node wird einzeln unsealed. Workshop-/Lern-Setup, kein Produktions-Deployment.

---

## Wozu ein Cluster — und wozu Docker dafür

Ein einzelner OpenBao-Container ist kein HA-Setup: stirbt er, ist der Vault weg.  
Ein **Cluster** aus mehreren Nodes mit Integrated [[raft|Raft]]-Storage löst das — die Nodes einigen sich per Konsens auf eine einzige Wahrheit und tolerieren Ausfälle (drei Nodes ⇒ ein Node darf ausfallen.

Docker Compose ist der schnellste Weg, dieses Cluster-Verhalten **lokal zum Lernen und Testen** zu erleben:  
drei Container statt drei Maschinen, Join/Leader-Wahl/Unseal-pro-Node real durchspielen, in Minuten weggeworfen. Für echte Produktion gehört der Cluster auf getrennte VMs oder Kubernetes.   

## Prinzip (aus der Vorlage)

Der Aufbau aus `raw/compose-cluster.md` (source: `raw/compose-cluster.md`):

- **3 OpenBao-Container** starten.
- Storage-Backend: **Integrated Raft** (jeder Node hält eine vollständige, replizierte Kopie).
- **Node 1 initialisiert** den Cluster.
- **Node 2 und 3 joinen** später Node 1.
- Host-Ports: `bao-1` → 8200, `bao-2` → 8201, `bao-3` → 8202.

> **Wichtige Klarstellung zu den Ports.** Die Ports 8201/8202 aus der Vorlage sind **Host-seitige Mappings** auf den jeweils containerinternen **API-Port 8200** — *nicht* der Raft-Cluster-Port. OpenBao nutzt containerintern immer zwei Ports: **8200 = API** (HTTP/HTTPS für Clients) und **8201 = Cluster-Port** (node-to-node, mTLS, intern generiertes Zertifikat — siehe [[raft]]). Der Cluster-Verkehr läuft also *innerhalb* des Docker-Netzes über 8201 und muss gar nicht nach außen gemappt werden. Verwechselt man Host-Port 8201 (= bao-2s API) mit dem Cluster-Port, ist die Konfusion vorprogrammiert. Diese Seite hält die beiden Rollen sauber getrennt.

## Verzeichnis-Layout

Der minimale Workshop-Aufbau, hier mit `bao.hcl` je Node ausgefüllt:

```
openbao-workshop/
├── docker-compose.yml
├── config/
│   ├── bao-1.hcl
│   ├── bao-2.hcl
│   └── bao-3.hcl
└── data/
    ├── bao-1/
    ├── bao-2/
    └── bao-3/
```

OpenBao wird per HCL oder JSON konfiguriert; für jeden Node schreibt man also eine eigene `bao.hcl` (source: `raw/compose-cluster.md`). Die drei Dateien unterscheiden sich nur in `**node_id**` und `**cluster_addr`/`api_addr**`.

## Die Node-Konfiguration

`config/bao-1.hcl`:

```hcl
ui = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "bao-1"

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
cluster_addr = "https://bao-1:8201"

# Adresse, unter der dieser Node von Clients/Peers erreichbar ist (landet in Redirects).
api_addr     = "http://bao-1:8200"
```

`config/bao-2.hcl` und `config/bao-3.hcl` sind identisch bis auf die drei markierten Werte:


| Datei       | `node_id` | `cluster_addr`       | `api_addr`          |
| ----------- | --------- | -------------------- | ------------------- |
| `bao-1.hcl` | `bao-1`   | `https://bao-1:8201` | `http://bao-1:8200` |
| `bao-2.hcl` | `bao-2`   | `https://bao-2:8201` | `http://bao-2:8200` |
| `bao-3.hcl` | `bao-3`   | `https://bao-3:8201` | `http://bao-3:8200` |


Felder-Erklärung (Referenz: [[configuration]], [[raft]]):

- `**storage "raft"**` mit eigenem `path` und eindeutigem `node_id` je Node. `path` zeigt auf das gemountete Daten-Volume; dort liegt die BoltDB (`raft.db`).
- `**cluster_addr` ist bei Raft Pflicht** — der Cluster muss wissen, unter welcher Adresse die Nodes ihren mTLS-Verkehr abwickeln (source: `raw/docs/configuration/storage/raft.md`, siehe [[raft]]). Die Hostnamen `bao-1`/`bao-2`/`bao-3` sind die Docker-Service-Namen und im Compose-Netz automatisch auflösbar. `**https`** ist hier korrekt, obwohl der API-Listener `tls_disable` hat: der Cluster-Port verschlüsselt seinen Verkehr immer mit einem intern erzeugten, rotierenden Zertifikat ([[raft]]) — eine häufige Stolperfalle.
- `**retry_join`** (eine Stanza je Kandidat) macht den Beitritt **config-basiert** statt per CLI-Befehl: jeder Node versucht beim Start automatisch, einen erreichbaren Leader zu finden (source: `raw/docs/concepts/integrated-storage/index.md`, `raw/docs/configuration/storage/raft.md`). Das ist robuster als der einmalige CLI-Join — überlebt Neustarts und Reihenfolge-Probleme. Die Vorlage zeigt den CLI-Weg (siehe unten); `retry_join` ist die empfohlene Alternative.
- `**api_addr`** darf nicht `127.0.0.1` bleiben, sobald Peers/Clients über den Namen kommen — sonst brechen Redirects/Forwarding ([[configuration]], [[load-balancing]]).

## Die Compose-Datei

`docker-compose.yml`:

```yaml
services:
  bao-1:
    image: openbao/openbao:latest
    container_name: bao-1
    ports:
      - "8200:8200"          # Host 8200 → bao-1 API
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config/bao-1.hcl:/openbao/config/bao.hcl:ro
      - ./data/bao-1:/openbao/data
    command: server -config=/openbao/config/bao.hcl
    restart: unless-stopped

  bao-2:
    image: openbao/openbao:latest
    container_name: bao-2
    ports:
      - "8201:8200"          # Host 8201 → bao-2 API (NICHT der Cluster-Port!)
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config/bao-2.hcl:/openbao/config/bao.hcl:ro
      - ./data/bao-2:/openbao/data
    command: server -config=/openbao/config/bao.hcl
    restart: unless-stopped

  bao-3:
    image: openbao/openbao:latest
    container_name: bao-3
    ports:
      - "8202:8200"          # Host 8202 → bao-3 API
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config/bao-3.hcl:/openbao/config/bao.hcl:ro
      - ./data/bao-3:/openbao/data
    command: server -config=/openbao/config/bao.hcl
    restart: unless-stopped
```

Erklärung (Container-Pfade extern verifiziert, siehe [[docker]]):

- `**command: server -config=…**` startet `bao server` mit der gemounteten Konfig (Referenz: [[commands-cli]]).
- Jeder Service mountet **seine eigene** `bao-N.hcl` read-only nach `/openbao/config/bao.hcl` und **sein eigenes** Daten-Verzeichnis nach `/openbao/data`.
- **Kein eigenes Netzwerk nötig**: Compose legt automatisch ein Default-Netz an, in dem sich die Services per Name (`bao-1`, `bao-2`, `bao-3`) erreichen — genau das, was `cluster_addr`/`retry_join` brauchen.
- `**IPC_LOCK`** erlaubt `mlock` (Secrets nicht auf Platte auslagern); alternativ `disable_mlock = true` in der Konfig (siehe Hardening in [[docker]]).
- Der **Cluster-Port 8201** wird *nicht* nach außen gemappt — er wird nur containerintern zwischen den Nodes gebraucht.

## Lokaler Start

```bash
docker compose up -d
docker compose logs -f bao-1   # erwartet: "core: security barrier not initialized"
```

Alle drei Container laufen jetzt, sind aber **uninitialisiert und sealed**. Raft hat noch keinen Cluster — Node 2 und 3 versuchen per `retry_join`, einen Leader zu finden, der aber erst nach Init/Unseal von Node 1 existiert.

## Initialisieren (nur Node 1)

Der Cluster wird **genau einmal** über **einen** Node initialisiert. Init erzeugt den Verschlüsselungs-Barrier, die Unseal-Key-Shares und den initialen Root-Token (Referenz: [[seal-unseal]], [[commands-cli]]).

> **Korrektur zur Vorlage.** Die Vorlage setzt `export BAO_ADDR=…` und ruft dann die CLI. Für die **Verbindung** liest die `bao`-CLI aber `VAULT_ADDR`/`VAULT_TOKEN` (Vault-kompatibel), nicht `BAO_ADDR` — siehe die ausführliche Erklärung in [[docker]] (Gotcha gemischte Präfixe; extern verifiziert: `openbao.org/docs/commands/`). Wer `BAO_ADDR` setzt, wundert sich, dass die CLI weiter `127.0.0.1:8200` ansteuert (was hier zufällig bao-1 ist — fällt also erst bei bao-2/3 auf). Sauberer ist, die CLI **im jeweiligen Container** auszuführen:

```bash
docker compose exec bao-1 bao operator init
```

Standardmäßig erhältst du **5 Unseal-Key-Shares**, einen **Threshold von 3** und den **Initial Root Token** (Referenz: [[seal-unseal]]):

```
Unseal Key 1: <…>
Unseal Key 2: <…>
Unseal Key 3: <…>
Unseal Key 4: <…>
Unseal Key 5: <…>

Initial Root Token: s.<…>
```

> **Diese Ausgabe erscheint genau einmal.** Sicher speichern. **Merke dir genau diese Shares** — Node 2 und 3 werden mit *denselben* Keys entsiegelt (siehe unten).
>
> Für reine Test-Clusters: `bao operator init -key-shares=1 -key-threshold=1`. Produktiv besser Auto-Unseal per KMS statt Shamir — siehe [[seal-unseal]].

### Node 1 unsealen

```bash
docker compose exec bao-1 bao operator unseal   # Key 1
docker compose exec bao-1 bao operator unseal   # Key 2
docker compose exec bao-1 bao operator unseal   # Key 3
```

Nach dem dritten Share zeigt `bao status` `Sealed false`. Node 1 ist jetzt **Leader** eines Ein-Node-Raft-Clusters.

## Weitere Nodes joinen

Sobald Node 1 entsiegelt ist, existiert ein Leader, dem 2 und 3 beitreten können. Zwei Wege:

### Variante 1 — automatisch per `retry_join` (empfohlen)

Steht `retry_join` in `bao-2.hcl`/`bao-3.hcl` (siehe oben), **haben die Nodes bereits selbst versucht beizutreten**, sobald Node 1 Leader wurde. Du musst sie nur noch **unsealen**:

```bash
docker compose exec bao-2 bao operator unseal   # Key 1
docker compose exec bao-2 bao operator unseal   # Key 2
docker compose exec bao-2 bao operator unseal   # Key 3
```

…und dasselbe für `bao-3`.

### Variante 2 — manuell per CLI (wie in der Vorlage)

Ohne `retry_join` joint man explizit. Die Vorlage nutzt `BAO_ADDR` und den CLI-Join (source: `raw/compose-cluster.md`); korrekt im Container ausgeführt:

```bash
docker compose exec bao-2 bao operator raft join http://bao-1:8200
docker compose exec bao-2 bao operator unseal   # 3× mit denselben Keys wie Node 1
```

> **Der Join nutzt den API-Port (8200), nicht den Cluster-Port** — wegen des Challenge/Answer-Bootstraps über die API (Henne-Ei-Problem mit den Cluster-Zertifikaten, ausführlich in [[raft]], source: `raw/docs/concepts/integrated-storage/index.md`).

### Warum dieselben Unseal-Keys?

Der Join überträgt die Cluster-TLS-Zertifikate per verschlüsseltem Challenge/Answer. Damit das funktioniert, **müssen alle Nodes denselben Seal teilen** (source: `raw/docs/internals/integrated-storage.md`, siehe [[raft]]):

- Bei **Shamir** (dieses Setup) heißt das: Node 2 und 3 werden mit **genau den Unseal-Keys von Node 1** entsiegelt. Eigene `init`-Läufe auf 2/3 wären falsch — der Cluster wird nur einmal initialisiert.
- Bei **Auto-Unseal** (KMS/Transit) entfällt das manuelle Unseal komplett und jeder Node entsiegelt sich selbst — produktiv der Standard.

> **Jeder Node wird einzeln entsiegelt; Unseal propagiert nicht im Cluster** ([[seal-unseal]]). Nach jedem Container-Neustart ist erneutes Unseal nötig — der Hauptgrund, produktiv Auto-Unseal zu verwenden.

## Cluster prüfen

```bash
# To avoid retyping the token on every command, log in once inside the container so the token gets cached to ~/.vault-token
docker compose exec -it bao-1 bao login

docker compose exec bao-1 bao operator raft list-peers
docker compose exec bao-1 bao status
```

`list-peers` sollte alle drei Nodes als `**voter**` zeigen (source: `raw/compose-cluster.md`, Referenz [[raft]]):

```text
Node     Address       State       Voter
----     -------       -----       -----
bao-1    bao-1:8201    leader      true
bao-2    bao-2:8201    follower    true
bao-3    bao-3:8201    follower    true
```

Bequemer Gesundheits-Blick mit Autopilot:

```bash
docker compose exec bao-1 bao operator raft autopilot state
```

`Failure Tolerance: 1` bei drei Votern bedeutet: ein Node darf jetzt ausfallen, ohne dass der Cluster das Quorum (2 von 3) verliert.

## Login & erste Schritte

UI im Browser (Node 1):

```
http://localhost:8200/ui
```

Auth-Methode **Token**, den **Initial Root Token** eintragen. Node 2 erreichst du über `http://localhost:8201/ui`, Node 3 über `http://localhost:8202/ui` — alle drei zeigen dieselben Daten, weil Raft repliziert (Schreibvorgänge gehen intern immer an den Leader, siehe [[high-availability]]).

CLI gegen den Cluster (vom Host, falls `bao` installiert) — beachte `VAULT_ADDR`:

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
bao login <Initial-Root-Token>
bao operator raft list-peers
```

> Den Root-Token nur fürs initiale Setup nutzen, danach reguläre [[auth|Auth-Methoden]] + [[policies]] einrichten und mit eingeschränkten [[tokens]] arbeiten.

## Ausfall ausprobieren (das Lern-Highlight)

Genau hierfür baut man den Cluster lokal. Leader killen und zusehen, wie ein Follower übernimmt:

```bash
docker compose stop bao-1
docker compose exec bao-2 bao operator raft list-peers   # neuer Leader unter bao-2 oder bao-3
docker compose exec bao-2 bao status                      # läuft weiter, Quorum 2/3 erhalten
```

Node 1 wieder starten — er kommt als Follower zurück, **muss aber erneut entsiegelt werden** (Shamir):

```bash
docker compose start bao-1
docker compose exec bao-1 bao operator unseal   # 3×
```

Fällt ein **zweiter** Node aus, ist das Quorum verloren und der Cluster nimmt keine Schreibvorgänge mehr an (Raft ist CP, siehe [[raft]] Level 1 und Recovery in Level 5).

## Aufräumen

```bash
docker compose down            # Container weg, ./data/ bleibt
docker compose down -v         # falls Named Volumes; hier liegen Daten in ./data/
rm -rf data/bao-*/             # Daten wirklich löschen → nächster Start ist frisch
```

> **Achtung beim Neu-Init.** Liegen in `./data/bao-*/` noch alte Raft-Daten, startet OpenBao nicht „frisch", sondern versucht den alten Cluster fortzusetzen. Für einen sauberen Neustart die `data/`-Verzeichnisse leeren.

## Vom Workshop zur Produktion

Was dieses Compose-Setup **bewusst weglässt** und produktiv unverzichtbar ist:

- **Getrennte Ausfalldomänen** — drei Container auf einem Host sind kein HA. Produktiv: drei VMs / Kubernetes-Nodes über Zonen verteilt ([[deployment-vm-vs-k8s]], [[k8s-ha-setup]]).
- **TLS am API-Listener** — hier `tls_disable`; produktiv echte Zertifikate ([[docker]] Abschnitt DNS/TLS, [[load-balancing]]).
- **Auto-Unseal** — manuelles Unseal pro Node nach jedem Restart ist operativ untragbar; produktiv KMS/HSM/Transit ([[seal-unseal]]).
- **Load Balancer** — eine stabile Adresse vor dem Cluster, der auf den aktiven Node zeigt (`/v1/sys/health`), siehe [[load-balancing]].
- **5 statt 3 Nodes** — die Reference-Architecture empfiehlt 5 Voter (Failure Tolerance 2), siehe [[raft]] Level 4.
- **Backups** — Snapshots regelmäßig sichern, Restore üben ([[backups]], [[raft]] Level 5).
- **Audit** — nach dem Login zwei [[audit]]-Devices aktivieren.

