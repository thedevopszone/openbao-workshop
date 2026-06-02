# Dynamische Secrets — Transit, DB-Credentials on demand, PKI

**Summary**:

Der eigentliche Mehrwert von OpenBao gegenüber „verschlüsseltem Key/Value-Store": Engines, die Geheimnisse **erzeugen statt verwahren**. Drei Beispiele in der CLI: **Transit** (Ver-/Entschlüsseln, ohne dass der Key je rausgeht), **Database Dynamic Roles** (kurzlebige DB-User, die automatisch ablaufen — der Unterschied zur Static Role aus dem k8s-Teil) und **PKI** (eigene CA, Zertifikate on demand). Voraussetzung: entsiegelter Server, Admin-Login, Grundlagen aus `5-secrets-cli.md` und `6-auth-und-policies.md`.

---

## Statisch vs. dynamisch — der Kernunterschied

| | **Statisch** (KV) | **Dynamisch** (database/pki/transit) |
| ------------- | --------------------------- | --------------------------------------------- |
| Herkunft | du legst den Wert ab | OpenBao **erzeugt** ihn bei der Anfrage |
| Lebensdauer | bis du ihn änderst | **TTL** — läuft automatisch ab (Lease) |
| Bei Leak | manuell rotieren | revoke / läuft ohnehin bald ab |
| Beispiel | API-Key, Config-Wert | DB-Login pro Request, frisches TLS-Zertifikat |

Dynamische Secrets haben einen **Lease**: einen Mietvertrag mit Ablaufzeit. OpenBao räumt sie selbst wieder ab — kompromittierte Credentials sind dadurch nur kurz nützlich.

```bash
bao lease lookup <lease_id>   # Restlaufzeit
bao lease renew  <lease_id>   # verlängern
bao lease revoke <lease_id>   # sofort ungültig (DB-User wird gelöscht etc.)
```

---

## Teil 1 — Transit: Encryption-as-a-Service

Transit kennst du schon als Auto-Unseal-Backend (`3-kubernetes.md`). Eigentlich ist es **Verschlüsselung als Dienst**: Anwendungen schicken Klartext hin und bekommen Chiffretext zurück — der **Schlüssel verlässt OpenBao nie**, die App speichert ihn nie. Kein eigenes Krypto im Code, zentrale Key-Rotation.

```bash
bao secrets enable transit

# einen benannten Schlüssel anlegen
bao write -f transit/keys/orders
```

**Verschlüsseln** (Klartext muss base64 sein):

```bash
bao write transit/encrypt/orders \
  plaintext=$(echo -n "Kreditkarte 4111-1111" | base64)
# -> ciphertext: vault:v1:xxxxxxxx...
```

**Entschlüsseln:**

```bash
bao write -field=plaintext transit/decrypt/orders \
  ciphertext="vault:v1:xxxxxxxx..." | base64 --decode
```

> Das `vault:v1:`-Präfix kodiert die **Key-Version**. Genau das macht Rotation einfach:

```bash
bao write -f transit/keys/orders/rotate     # neue Version v2; Alt-Daten weiter lesbar
bao write transit/rewrap/orders ciphertext="vault:v1:..."  # auf v2 umschlüsseln, ohne Klartext zu sehen
```

Weitere nützliche Operationen: `transit/datakey/plaintext/orders` erzeugt einen **Data Key** für Envelope-Encryption (großer Datenmengen verschlüsselt man lokal mit dem Data Key, der wiederum von Transit geschützt ist), und `transit/sign` / `transit/verify` für Signaturen.

> **Use-Case:** App will Felder in ihrer eigenen DB verschlüsseln, ohne Key-Management zu bauen. Sie ruft nur `encrypt`/`decrypt` auf. Wird der Key kompromittiert-verdächtig, rotiert *ein* Admin zentral — die App merkt nichts.

---

## Teil 2 — Dynamische DB-Credentials (vs. Static Role)

Im k8s-Teil rotiert eine **Static Role** das Passwort eines *bestehenden* Users (`files/3-kubernetes/terraform/database.tf`). Eine **Dynamic Role** geht weiter: Sie **legt bei jeder Anfrage einen neuen DB-User an**, der nach Ablauf der TTL **automatisch gelöscht** wird.

| | **Static Role** (im Workshop) | **Dynamic Role** (hier) |
| ----------- | ------------------------------- | ------------------------------------ |
| User | bestehend, bleibt | **pro Anfrage neu erzeugt** |
| Passwort | wird periodisch rotiert | gilt nur für diesen Lease |
| Ablauf | dauerhaft, Passwort wechselt | User wird bei TTL-Ende **gelöscht** |
| Befehl | `kv`-artig lesen | `bao read database/creds/<rolle>` |
| Eignung | Legacy-App mit festem User | jeder neue Service, Audit pro Zugriff |

Setup (gegen die Postgres-Instanz aus `files/3-kubernetes/postgres/docker-compose.yml`):

```bash
bao secrets enable database

# Verbindung (Connection-User darf User anlegen/löschen)
bao write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-dynamic" \
  connection_url="postgresql://{{username}}:{{password}}@host.k3d.internal:5432/appdb?sslmode=disable" \
  username="postgres" \
  password="changeme"

# Dynamic Role: was beim Erzeugen/Aufräumen eines Users passiert
bao write database/roles/app-dynamic \
  db_name=postgres \
  default_ttl=1h \
  max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
```

Credentials anfordern — jeder Aufruf liefert **andere** Zugangsdaten:

```bash
bao read database/creds/app-dynamic
```

```
Key                Lease ID / Werte
---                ----------------
lease_id           database/creds/app-dynamic/AbC123...
lease_duration     1h
password           A1b2-randomly-generated
username           v-token-app-dyn-x7Yz...
```

Der User `v-token-app-dyn-...` existiert jetzt real in Postgres und verschwindet nach 1 h von selbst — oder sofort per `bao lease revoke <lease_id>`.

> **Aha-Moment:** Es gibt keine langlebigen DB-Passwörter mehr, die irgendwo „rumliegen". Jeder Service holt sich beim Start frische, ablaufende Credentials. Leak = wertlos nach kurzer Zeit, und jeder Zugriff ist über den Username einer Identität zuordenbar.

Passende Policy (analog zu `db-app-read` in `database.tf`, nur für den dynamischen Pfad):

```hcl
path "database/creds/app-dynamic" {
  capabilities = ["read"]
}
```

---

## Teil 3 — PKI: eigene CA, Zertifikate on demand

Statt Zertifikate manuell mit OpenSSL zu basteln, wird OpenBao zur **Certificate Authority**: kurzlebige TLS-Zertifikate per API, mit erzwungenen Regeln (erlaubte Domains, max. TTL).

```bash
bao secrets enable pki
bao secrets tune -max-lease-ttl=87600h pki     # 10 Jahre für die Root-CA

# selbstsignierte Root-CA erzeugen
bao write -field=certificate pki/root/generate/internal \
  common_name="workshop.local" \
  ttl=87600h > ca.crt

# URLs für CRL/Issuer (für Clients, die die Kette prüfen)
bao write pki/config/urls \
  issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
  crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
```

Eine **Rolle** legt fest, *welche* Zertifikate ausgestellt werden dürfen:

```bash
bao write pki/roles/web \
  allowed_domains="workshop.local" \
  allow_subdomains=true \
  max_ttl=72h
```

Zertifikat ausstellen (Key + Cert kommen frisch zurück):

```bash
bao write pki/issue/web common_name="app.workshop.local" ttl=24h
# -> certificate, private_key, ca_chain, serial_number
```

Widerrufen vor Ablauf:

```bash
bao write pki/revoke serial_number="<serial>"
```

> **Use-Case:** interne Service-to-Service-mTLS. Jeder Dienst zieht beim Start ein 24-h-Zertifikat; Rotation passiert automatisch durch erneutes Ausstellen. Für Produktion nimmt man eine **Intermediate CA** (Root offline halten) — selber Mechanismus, nur mit `pki/intermediate/...`.

---

## Spickzettel

```bash
# Transit (Encryption as a Service)
bao secrets enable transit
bao write -f transit/keys/orders
bao write transit/encrypt/orders plaintext=$(echo -n "geheim" | base64)
bao write -field=plaintext transit/decrypt/orders ciphertext="vault:v1:..." | base64 -d
bao write -f transit/keys/orders/rotate

# Dynamische DB-Credentials
bao secrets enable database
bao write database/config/postgres plugin_name=postgresql-database-plugin ...
bao write database/roles/app-dynamic db_name=postgres default_ttl=1h creation_statements="..."
bao read  database/creds/app-dynamic          # frische, ablaufende Logins

# PKI
bao secrets enable pki
bao write pki/root/generate/internal common_name="workshop.local" ttl=87600h
bao write pki/roles/web allowed_domains="workshop.local" allow_subdomains=true max_ttl=72h
bao write pki/issue/web common_name="app.workshop.local" ttl=24h

# Leases (für alle dynamischen Secrets)
bao lease lookup/renew/revoke <lease_id>
```

> Fertige Dateien: `files/7-dynamic-secrets/` — Policies (`transit-app.hcl`, `db-dynamic-read.hcl`, `pki-issue.hcl`) und ein `setup-dynamic.sh`, das Transit, dynamische DB-Rolle und PKI einrichtet.

---

## Roter Faden

1. `5-secrets-cli.md` — statische Secrets (KV) schreiben/lesen.
2. `6-auth-und-policies.md` — Zugriff ohne Root: Auth-Methoden, Policies, Tokens.
3. **Dieses Kapitel** — dynamische Secrets: Transit, DB-Credentials on demand, PKI.

Damit ist der Bogen komplett: vom Aufsetzen (Teile 0–4) über das Absichern des Zugriffs bis zu den Engines, die OpenBao von einem Tresor zu einem aktiven Credential-Lieferanten machen. Operativ schließen sich an: **Audit** (`6-auth-und-policies.md`), **Raft-Snapshots** (Backup/Restore) und **Key-Rotation** (`operator rekey`/`rotate`).
