# Auth-Methoden & Policies — Zugriff ohne Root-Token

**Summary**:

Wie man in OpenBao den **Root-Token wegkommt** und stattdessen mit echten **Auth-Methoden** (Menschen über `userpass`/OIDC, Maschinen über `AppRole`, Pods über `kubernetes`) einloggt — und wie **Policies** steuern, *wer auf welchen Pfad mit welchem Recht* zugreift. Außerdem: Tokens verstehen (TTL, renew, revoke). Voraussetzung: laufender, entsiegelter Server, eingeloggt als Admin (siehe `1-docker-single-node.md`, `5-secrets-cli.md`).

---

## Warum überhaupt — der Root-Token ist kein Account

Bis hierher haben wir alles mit dem **Initial Root Token** gemacht. Das ist bewusst nur fürs Setup gedacht: Er hat **uneingeschränkte Rechte**, läuft nie ab und gehört keinem Menschen. In der Praxis macht man genau zwei Dinge:

1. Mit dem Root-Token einmalig **Auth-Methoden + Policies** einrichten.
2. Den Root-Token **widerrufen** (`bao token revoke`) und ab dann mit eingeschränkten Identitäten arbeiten.

Drei Bausteine spielen zusammen:

| Baustein | Frage | Beispiel |
| ------------- | --------------------------- | ------------------------------------ |
| **Auth-Methode** | *Wer bist du?* (Authentifizierung) | userpass, AppRole, OIDC, kubernetes |
| **Policy** | *Was darfst du?* (Autorisierung) | „read auf `kv/data/workshop/*`" |
| **Token** | *Dein Ausweis* nach dem Login | kurzlebig, an Policies gebunden |

Ablauf: Login über eine Auth-Methode → OpenBao gibt einen **Token** zurück → an diesem Token hängen **Policies** → jede weitere Anfrage wird gegen die Policies geprüft.

> **Default-deny.** Ohne passende Policy ist *alles* verboten. Man erlaubt gezielt einzelne Pfade — nie andersherum.

---

## Teil 1 — Policies: das „Was darfst du"

Eine Policy ist HCL: pro **Pfad** eine Liste von **Capabilities**.

```hcl
# datei: workshop-read.hcl
path "kv/data/workshop/*" {
  capabilities = ["read", "list"]
}
```

Die Capabilities entsprechen grob den HTTP-Verben der API:

| Capability | bedeutet | typischer Befehl |
| ---------- | -------------------------------- | --------------------- |
| `create` | neu anlegen | `kv put` (neu) |
| `update` | ändern/überschreiben | `kv put` (bestehend), `kv patch` |
| `read` | lesen | `kv get` |
| `list` | Pfade auflisten | `kv list` |
| `delete` | löschen | `kv delete` |
| `sudo` | privilegierte `sys/`-Pfade | z. B. Rekey |
| `deny` | **explizit verbieten** (sticht alles) | — |

Policy schreiben und prüfen:

```bash
bao policy write workshop-read workshop-read.hcl
bao policy list
bao policy read workshop-read
```

### Der KV-v2-Pfad-Stolperstein

Bei **KV v2** liegt das Secret unter `kv/workshop/hello`, die API-Pfade haben aber eine **Zwischenebene** (siehe `5-secrets-cli.md`). Die Policy muss diese Ebene treffen:

| Aktion | Pfad in der Policy |
| --------------------------- | ----------------------------- |
| Secret lesen/schreiben | `kv/data/workshop/*` |
| Secret löschen (soft) | `kv/delete/workshop/*` |
| Endgültig vernichten | `kv/destroy/workshop/*` |
| Metadaten/Versionen, `kv list` | `kv/metadata/workshop/*` |

> Häufigster Fehler: Policy auf `kv/workshop/*` statt `kv/data/workshop/*` → „permission denied" beim `kv get`, obwohl der Pfad „richtig" aussieht. Bei **KV v1** entfällt das `data/` und der Pfad ist direkt `kv/workshop/*`.

### Pfad-Muster

- `*` am **Ende** = Glob über den Rest (`kv/data/workshop/*`).
- `+` = genau **ein** Segment (`kv/data/+/config` matcht `kv/data/team-a/config`).
- Längster passender Pfad gewinnt; `deny` schlägt jede Erlaubnis.

### Eigene Rechte prüfen

```bash
bao token capabilities kv/data/workshop/hello   # -> read, list
```

---

## Teil 2 — userpass: Login für Menschen

Die einfachste Auth-Methode: Benutzername + Passwort. Aktivieren, User anlegen, Policy zuweisen:

```bash
bao auth enable userpass

bao write auth/userpass/users/workshop \
  password="workshop123" \
  policies="workshop-read"
```

Einloggen (als „normaler" User, nicht Root):

```bash
bao login -method=userpass username=workshop
# Password: ********
```

OpenBao gibt einen **Token** mit genau den Rechten der Policy zurück. Test:

```bash
bao kv get  kv/workshop/hello     # ✅ erlaubt (read)
bao kv put  kv/workshop/hello x=y # ❌ permission denied (kein create/update)
bao kv get  kv/db/myapp           # ❌ permission denied (anderer Pfad)
```

> Genau dieser User + diese Policy werden im k8s-Teil per OpenTofu erzeugt (`files/3-kubernetes/terraform/main.tf`). Hier siehst du, was dort im Hintergrund passiert.

Weitere Auth-Methoden für Menschen laufen analog, nur mit anderem `-method`: **OIDC** (Login per Browser gegen Keycloak/Entra/Google), **LDAP** (Firmenverzeichnis). Prinzip bleibt: Auth-Methode aktivieren → externe Identität auf Policies mappen.

---

## Teil 3 — AppRole: Login für Maschinen (CI/CD, Apps)

Maschinen haben kein Passwort, das ein Mensch tippt. **AppRole** liefert zwei Geheimnisse: eine **RoleID** (wie ein Benutzername, eher statisch) und eine **SecretID** (wie ein Passwort, kurzlebig/rotierbar). Der Klassiker für Pipelines.

```bash
bao auth enable approle

# Rolle, die nur die workshop-read-Policy bekommt
bao write auth/approle/role/ci \
  token_policies="workshop-read" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=10m

# RoleID auslesen (statisch, darf in die Config der App)
bao read auth/approle/role/ci/role-id

# SecretID erzeugen (kurzlebig, frisch pro Deploy)
bao write -f auth/approle/role/ci/secret-id
```

Login mit beiden Teilen → Token:

```bash
bao write auth/approle/login \
  role_id="<role-id>" \
  secret_id="<secret-id>"
```

> **Best Practice:** RoleID und SecretID **nie zusammen** ausliefern. Die SecretID gehört frisch und kurzlebig zur Laufzeit übergeben — idealerweise per **Response Wrapping** (`-wrap-ttl=...`), sodass nur der echte Empfänger sie einmalig auspacken kann.

Für **Kubernetes** gibt es die native `kubernetes`-Auth-Methode: Pods authentifizieren sich mit ihrem ServiceAccount-Token, ganz ohne hinterlegte Secrets — die saubere Alternative zum statischen Token, den ESO im k8s-Teil nutzt (siehe `3-kubernetes.md`).

---

## Teil 4 — Tokens verstehen

Jeder Login erzeugt einen **Token**. Wichtige Eigenschaften:

```bash
bao token lookup          # Infos zum eigenen Token: TTL, Policies, ...
bao token renew           # Lebenszeit verlängern (bis max_ttl)
bao token revoke <token>  # sofort ungültig machen
```

- **TTL / max_ttl** — Token laufen ab. Kurzlebig ist gut; abgelaufene Tokens richten keinen Schaden an.
- **service vs. batch** — service-Tokens sind voll verwaltet (renew/revoke, in Storage); batch-Tokens sind leichtgewichtig/zustandslos für hohe Last.
- **orphan** — normalerweise sterben Child-Tokens mit dem Parent; orphan-Tokens überleben das (für langlebige Dienste).

### Den Root-Token loswerden

Sobald Auth-Methoden + Policies stehen, ist der Root-Token überflüssig:

```bash
bao token revoke -self      # als Root ausgeführt: widerruft den Root-Token
```

> Du brauchst echten Root nur noch sehr selten (z. B. Rekey). Dann erzeugst du ihn **temporär neu** über `bao operator generate-root` mit den Unseal-/Recovery-Keys (siehe `3-kubernetes.md`, Abschnitt „Wenn du wieder echten Root brauchst"). Danach wieder widerrufen.

---

## Teil 5 — Audit aktivieren (jetzt wird's prüfbar)

Sobald echte Identitäten zugreifen, willst du nachvollziehen können, **wer wann was** angefragt hat. Ein Audit-Device protokolliert jede Anfrage/Antwort (Secrets darin gehasht):

```bash
bao audit enable file file_path=/openbao/logs/audit.log
bao audit list
```

```bash
# danach z. B. fehlgeschlagene Zugriffe sehen
docker compose exec openbao sh -c 'grep "permission denied" /openbao/logs/audit.log'
```

> **Gotcha:** Lässt sich kein Audit-Device aktivieren (z. B. Pfad nicht schreibbar), kann OpenBao **blockieren**, wenn das einzige Device ausfällt — deshalb in Produktion **zwei** Devices. Im Workshop reicht eins; den Log-Volume hat Variante B schon (`openbao-logs`).

---

## Spickzettel

```bash
# Policies
bao policy write workshop-read workshop-read.hcl
bao policy list / read workshop-read
bao token capabilities kv/data/workshop/hello   # was darf ich hier?

# userpass (Menschen)
bao auth enable userpass
bao write auth/userpass/users/alice password="..." policies="workshop-read"
bao login -method=userpass username=alice

# AppRole (Maschinen)
bao auth enable approle
bao write auth/approle/role/ci token_policies="workshop-read" token_ttl=1h
bao read  auth/approle/role/ci/role-id
bao write -f auth/approle/role/ci/secret-id
bao write auth/approle/login role_id=... secret_id=...

# Tokens
bao token lookup / renew / revoke <token>
bao token revoke -self            # Root abschalten

# Audit
bao audit enable file file_path=/openbao/logs/audit.log
```

> Fertige Dateien: `files/6-auth-und-policies/` — Policies (`workshop-read.hcl`, `workshop-write.hcl`) und ein `setup-auth.sh`, das userpass, AppRole, Policies und Audit in einem Rutsch einrichtet.

---

## Roter Faden bis hierher

1. `5-secrets-cli.md` — Secrets schreiben/lesen (als Root).
2. **Dieses Kapitel** — Zugriff ohne Root: Auth-Methoden + Policies + Tokens.
3. Nächster Schritt — **dynamische Secrets** (`database` dynamic roles, `pki`, `transit`): Credentials, die OpenBao on demand erzeugt und automatisch ablaufen lässt, statt sie wie KV nur zu verwahren.
