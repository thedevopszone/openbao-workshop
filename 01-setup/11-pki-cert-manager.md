# OpenBao-PKI als cert-manager-Issuer

**Summary**:

Wie man die **OpenBao-PKI** (aus `7-dynamic-secrets.md`) als **interne CA** an **cert-manager** anbindet: cert-manager fordert über seinen eingebauten `vault`-Issuer Zertifikate bei OpenBao an, legt sie als K8s-`Secret` ab und **erneuert sie automatisch**. Damit bekommen Pods/Services kurzlebige mTLS-Zertifikate ohne manuelles Hantieren. Authentifizierung per nativer `kubernetes`-Auth (`9-agent-und-k8s-auth.md`).

---

## Abgrenzung zu Kapitel 3

In `3-kubernetes.md` nutzt cert-manager **Let's Encrypt** (öffentliche CA, DNS-01) für die **externe** Ingress-URL. Hier ist es umgekehrt: OpenBao ist eine **interne CA** für **clusterinterne** Zertifikate (Service-to-Service-mTLS, kurze TTLs). cert-manager kann beides parallel — pro Issuer eine Quelle.

| | Let's Encrypt (Kap. 3) | OpenBao-PKI (hier) |
| ----------- | ------------------------- | ------------------------------ |
| CA | öffentlich | eigene, interne |
| Einsatz | Browser/extern, Ingress | intern, mTLS zwischen Services |
| TTL | 90 Tage | Stunden/Tage, häufige Rotation |
| Issuer-Typ | `acme` | `vault` |

---

## Voraussetzungen

- PKI in OpenBao aktiviert, eine Rolle `web` mit erlaubten Domains (siehe `7-dynamic-secrets.md` / `files/7-dynamic-secrets/setup-dynamic.sh`).
- cert-manager installiert (siehe `3-kubernetes.md`, Abschnitt „Ingress (optional)").
- `kubernetes`-Auth aktiv (`9-agent-und-k8s-auth.md`).

---

## 1. OpenBao: Auth + Policy für cert-manager

cert-manager braucht das Recht, über die PKI-Rolle Zertifikate auszustellen (`pki/sign/web`):

```bash
# Policy: cert-manager darf signieren
bao policy write certmanager - <<'EOF'
path "pki/sign/web" {
  capabilities = ["create", "update"]
}
EOF

# kubernetes-Auth-Rolle, an cert-managers ServiceAccount gebunden
bao write auth/kubernetes/role/certmanager \
  bound_service_account_names="cert-manager" \
  bound_service_account_namespaces="cert-manager" \
  token_policies="certmanager" \
  token_ttl=20m
```

> `pki/sign/<rolle>` signiert einen vom Client erzeugten **CSR** (privater Schlüssel bleibt im Cluster). Alternativ `pki/issue/<rolle>`, das auch den Key erzeugt — für cert-manager ist der **sign**-Pfad der richtige, da cert-manager den Key selbst hält.

## 2. cert-manager: Issuer auf OpenBao zeigen lassen

`vault-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-pki
spec:
  vault:
    server: "http://openbao.openbao.svc:8200"
    path: "pki/sign/web"          # Sign-Pfad der PKI-Rolle
    auth:
      kubernetes:
        role: certmanager          # die OpenBao-Rolle aus Schritt 1
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager       # cert-managers eigener SA
```

```bash
kubectl apply -f vault-issuer.yaml
kubectl get clusterissuer openbao-pki -o wide      # Ready=True?
```

> Andere Auth-Methoden gehen auch: `auth.tokenSecretRef` (statischer Token) oder `auth.appRole` (siehe `6-auth-und-policies.md`). `kubernetes` ist die sauberste Variante — kein hinterlegtes Geheimnis.

## 3. Zertifikat anfordern

cert-manager holt das Zertifikat bei OpenBao und legt es als `Secret` ab — und erneuert es vor Ablauf automatisch:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: default
spec:
  secretName: web-tls               # erzeugtes K8s-Secret (tls.crt/tls.key)
  duration: 24h
  renewBefore: 8h
  commonName: app.workshop.local
  dnsNames:
    - app.workshop.local
  issuerRef:
    name: openbao-pki
    kind: ClusterIssuer
```

```bash
kubectl apply -f certificate.yaml
kubectl get certificate web-tls            # READY=True
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -enddate
```

Das `web-tls`-Secret mountet die App als Volume — bei Erneuerung schreibt cert-manager es neu (Kubelet aktualisiert das Volume, vgl. Rotationsverhalten in `3-kubernetes.md`).

---

## Wofür das gut ist

- **Service-to-Service-mTLS** intern, ohne selbstgebaute CA-Skripte.
- **Kurze TTLs** (Stunden) mit automatischer Erneuerung — kompromittierte Zertifikate sind schnell wertlos.
- Zentrale Kontrolle: `allowed_domains`/`max_ttl` der PKI-Rolle erzwingen, was ausgestellt werden darf (siehe `7-dynamic-secrets.md`).

> Produktiv: **Intermediate CA** statt Root direkt signieren lassen (Root offline), und die Root-CA als `caBundle`/Trust an die Clients verteilen.

---

## Spickzettel

```bash
# OpenBao-Seite
bao policy write certmanager -   # path "pki/sign/web" { capabilities=["create","update"] }
bao write auth/kubernetes/role/certmanager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  token_policies=certmanager token_ttl=20m

# cert-manager-Seite
kubectl apply -f vault-issuer.yaml      # ClusterIssuer kind: vault -> pki/sign/web
kubectl apply -f certificate.yaml       # Certificate -> Secret web-tls (auto-renew)
kubectl get clusterissuer,certificate -A
```

> Fertige Dateien: `files/11-pki-cert-manager/` — `setup-pki-certmanager.sh` (Policy + Rolle), `vault-issuer.yaml` und `certificate.yaml`.

---

## Roter Faden

1. `7-dynamic-secrets.md` — PKI in OpenBao (CA, Rolle, `issue`/`sign`).
2. `9-agent-und-k8s-auth.md` — native `kubernetes`-Auth (hier für cert-manager genutzt).
3. **Dieses Kapitel** — cert-manager zieht interne Zertifikate aus OpenBao-PKI und erneuert sie automatisch.
