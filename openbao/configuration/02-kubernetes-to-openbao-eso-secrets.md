# MariaDB Deployment mit OpenBao & External Secrets Operator (ESO)

## Übersicht

![](/images/openbao_eso_architecture_v2.svg)


## Anleitung 

Schritt-für-Schritt-Anleitung: Ein Secret (`MARIADB_ROOT_PASSWORD`) wird in OpenBao gespeichert und über den External Secrets Operator als natives Kubernetes Secret in den MariaDB-Pod injiziert.

> **Setup:** Alle Teilnehmer nutzen den **gleichen OpenBao-Server** (`https://openbao.jmetzger.do.t3isp.de`), aber jeder arbeitet mit seinem **eigenen Kubernetes-Cluster**. Damit sich die Teilnehmer nicht in die Quere kommen, bekommt jeder seinen eigenen Auth-Mount (`kubernetes-<cluster-name>`), eigenen Secret-Pfad (`secret/<cluster-name>/mariadb`) und eigene Policy (`mariadb-read-<cluster-name>`).

> **Warum ESO statt VSO?** Der HashiCorp Vault Secrets Operator (VSO) steht unter der BSL 1.1 Lizenz, die kommerzielle Nutzung einschränkt. Der External Secrets Operator ist ein CNCF-Projekt unter Apache 2.0 Lizenz, vendor-neutral und wird von OpenBao offiziell empfohlen. ESO unterstützt neben Vault/OpenBao auch AWS Secrets Manager, Azure Key Vault, GCP Secret Manager u.v.m.

---

## Voraussetzungen

- Eigenes Kubernetes-Cluster (z.B. RKE2, k3s, etc.)
- Gemeinsamer OpenBao-Server: `https://openbao.jmetzger.do.t3isp.de`
- `bao` CLI konfiguriert und authentifiziert (jeder TN hat Admin-Rechte)
- Helm v3 installiert
- Der K8s-Cluster muss den OpenBao-Server per HTTPS erreichen können
- **Dein Clustername**: z.B. `cluster-tn1`, `cluster-tn2`, … — wird durchgängig als `<cluster-name>` verwendet

---

## Prep 1: Done by trainer: Install bao executable

```bash
wget https://github.com/openbao/openbao/releases/download/v2.5.1/bao_2.5.1_Linux_x86_64.tar.gz
tar xzf bao_2.5.1_Linux_x86_64.tar.gz
sudo mv bao /usr/local/bin/
```

## Schritt 0: Clusternamen ermitteln und als Variable setzen

Den eigenen Clusternamen als Variable setzen — wird in allen folgenden Schritten verwendet:

```bash
export CLUSTER_NAME=cluster-jmetzger  # ← Anpassen auf deinen Clusternamen!
```

> **Tipp:** Wer den Clusternamen nicht kennt: `kubectl config current-context` zeigt den aktuellen Kontext.

> **Hinweis zu YAML-Dateien:** In Bash-Befehlen wird `$CLUSTER_NAME` automatisch aufgelöst. In YAML-Dateien muss `<cluster-name>` **manuell** durch den Clusternamen ersetzt werden (z.B. `cluster-tn1`).

---

## Schritt 1: KV Secrets Engine aktivieren

```bash
# Kann auch in die ~/.bashrc
export BAO_ADDR=https://openbao.jmetzger.do.t3isp.de
bao login -method=userpass username=admin
bao secrets enable -path=secret kv-v2
```

> Falls bereits aktiviert (z.B. von einem anderen TN), überspringen — die Fehlermeldung `path is already in use` ist harmlos.

---

## Schritt 2: Secret in OpenBao anlegen

Jeder Teilnehmer legt sein Secret unter seinem Clusternamen ab:

```bash
bao kv put secret/$CLUSTER_NAME/mariadb root-password="meinSuperGeheimesPasswort"
```

Kontrolle:

```bash
bao kv get secret/$CLUSTER_NAME/mariadb
```

---

## Schritt 3: Policy erstellen

```bash
cd
mkdir -p openbao-hcl/mariadb
cd openbao-hcl/mariadb
```

```bash
cat > mariadb-read-$CLUSTER_NAME.hcl <<EOF
path "secret/data/$CLUSTER_NAME/mariadb" {
  capabilities = ["read"]
}
EOF
```

Policy schreiben:

```bash
bao policy write mariadb-read-$CLUSTER_NAME mariadb-read-$CLUSTER_NAME.hcl
```

> **Hinweis:** Bei KV-v2 ist der tatsächliche Pfad immer `secret/data/<path>`, auch wenn man mit `bao kv` nur `secret/<path>` angibt.

---

## Schritt 4: External Secrets Operator (ESO) installieren

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true
```

Prüfen, ob der Operator läuft:

```bash
kubectl get pods -n external-secrets
```

> **Hinweis:** ESO erstellt einen eigenen ServiceAccount für den Operator, aber dieser dient nur dem Operator selbst. Er hat **keine** `system:auth-delegator`-Berechtigung und kann nicht für die TokenReview-Validierung durch OpenBao verwendet werden.

---

## Schritt 5: Kubernetes Auth Method aktivieren und konfigurieren

Da OpenBao **außerhalb** des Clusters läuft, muss es den API-Server erreichen und ServiceAccount-Tokens validieren können. Dafür braucht es explizit:

- `kubernetes_host` — API-Server-Adresse (von außen erreichbar)
- `kubernetes_ca_cert` — CA-Zertifikat des Clusters
- `token_reviewer_jwt` — ein langlebiger Token mit `system:auth-delegator`-Berechtigung

> **Warum ein eigener Auth-Mount pro Teilnehmer?** Ein Auth-Mount kann nur **einen** Kubernetes-Cluster bedienen (`kubernetes_host`, `kubernetes_ca_cert`, `token_reviewer_jwt` sind cluster-spezifisch). Da jeder TN sein eigenes Cluster hat, braucht jeder seinen eigenen Auth-Mount.

### 5a: ServiceAccount und ClusterRoleBinding für Token-Review anlegen (im eigenen Cluster)

```bash
kubectl create serviceaccount vault-auth -n default

kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=default:vault-auth
```

### 5b: Langlebigen Token erzeugen

```bash
nano vault-auth-token.yaml
```

```yaml
# vault-auth-token.yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
```

```bash
kubectl apply -f vault-auth-token.yaml
```

### 5c: Werte auslesen

```bash
# Token
TOKEN_REVIEWER_JWT=$(kubectl get secret vault-auth-token -o jsonpath='{.data.token}' | base64 -d)

# Kubernetes CA Cert
KUBE_CA_CERT=$(kubectl get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d)

# API Server Adresse
KUBE_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
```

### 5d: Auth Method in OpenBao aktivieren (eigener Mount pro TN)

```bash
bao auth enable -path=kubernetes-$CLUSTER_NAME kubernetes
```

### 5e: OpenBao konfigurieren

```bash
bao write auth/kubernetes-$CLUSTER_NAME/config \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA_CERT" \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT"
```

> **Wichtig:** `kubernetes_host` muss die **externe** Adresse des API-Servers sein, die vom OpenBao-Server aus erreichbar ist — nicht `https://kubernetes.default.svc:443`.

### 5f: Rolle anlegen

```bash
bao write auth/kubernetes-$CLUSTER_NAME/role/mariadb \
  bound_service_account_names=mariadb-sa \
  bound_service_account_namespaces=default \
  policies=mariadb-read-$CLUSTER_NAME \
  ttl=1h
```

---

## Schritt 6: ServiceAccount für MariaDB anlegen

```bash
nano mariadb-sa.yaml
```

```yaml
# mariadb-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mariadb-sa
  namespace: default
```

```bash
kubectl apply -f mariadb-sa.yaml
```

---

## Schritt 7: SecretStore erstellen

Der SecretStore teilt ESO mit, wie es sich mit OpenBao verbinden und authentifizieren soll.

```bash
nano secret-store.yaml
```

```yaml
# secret-store.yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: openbao-backend
  namespace: default
spec:
  provider:
    vault:
      server: "https://openbao.jmetzger.do.t3isp.de"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes-<cluster-name>"
          role: "mariadb"
          serviceAccountRef:
            name: "mariadb-sa"
```

> Falls OpenBao ein selbstsigniertes Zertifikat nutzt, muss `spec.provider.vault.caProvider` konfiguriert werden (z.B. via ConfigMap oder Secret mit dem CA-Cert).

```bash
kubectl apply -f secret-store.yaml
```

Prüfen, ob der SecretStore valid ist:

```bash
kubectl get secretstore openbao-backend
```

Der STATUS sollte `Valid` zeigen. Falls nicht:

```bash
kubectl describe secretstore openbao-backend
```

---

## Schritt 8: ExternalSecret erstellen

Das ExternalSecret definiert, welches Secret aus OpenBao geholt und wie das resultierende Kubernetes Secret aussehen soll.

```bash
nano external-secret.yaml
```

```yaml
# external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mariadb-secret
  namespace: default
spec:
  refreshInterval: "60s"
  secretStoreRef:
    name: openbao-backend
    kind: SecretStore
  target:
    name: mariadb-k8s-secret
    creationPolicy: Owner
  data:
    - secretKey: root-password
      remoteRef:
        key: <cluster-name>/mariadb
        property: root-password
```

```bash
kubectl apply -f external-secret.yaml
```

Prüfen, ob das Kubernetes Secret erstellt wurde:

```bash
kubectl get externalsecret mariadb-secret
kubectl get secret mariadb-k8s-secret -o yaml
```

> **Vergleich zu VSO:** Statt `VaultConnection` + `VaultAuth` + `VaultStaticSecret` (3 CRDs) braucht ESO nur `SecretStore` + `ExternalSecret` (2 CRDs). Die Authentifizierung ist direkt im SecretStore konfiguriert.

---

## Schritt 9: MariaDB Deployment ausrollen

```bash
nano mariadb-deployment.yaml
```

```yaml
# mariadb-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      serviceAccountName: mariadb-sa
      containers:
        - name: mariadb
          image: mariadb:11
          ports:
            - containerPort: 3306
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-k8s-secret
                  key: root-password
```

```bash
kubectl apply -f mariadb-deployment.yaml
```

---

## Schritt 10: Verifizieren

### Pod-Status prüfen

```bash
kubectl get pods -l app=mariadb
```

### Env-Variable im Pod prüfen

```bash
kubectl exec -it deploy/mariadb -- env | grep MARIADB_ROOT_PASSWORD
```

### MariaDB-Login testen

```bash
kubectl exec -it deploy/mariadb -- mariadb -uroot -p
```

---

## Überblick: ServiceAccounts in diesem Setup

| ServiceAccount | Namespace | Zweck |
|---|---|---|
| `vault-auth` | default | TokenReview – damit OpenBao von außen K8s-Tokens validieren kann |
| ESO-eigener SA | external-secrets | Operator-Betrieb – CRDs watchen, K8s Secrets anlegen |
| `mariadb-sa` | default | Pod-Identität + SecretStore-Auth – der SA authentifiziert sich bei OpenBao |

---

## Überblick: TN-spezifische Ressourcen auf dem gemeinsamen OpenBao-Server

| Ressource | Namensschema | Beispiel |
|---|---|---|
| Auth-Mount | `kubernetes-<cluster-name>` | `kubernetes-cluster-tn3` |
| Secret-Pfad | `secret/<cluster-name>/mariadb` | `secret/cluster-tn3/mariadb` |
| Policy | `mariadb-read-<cluster-name>` | `mariadb-read-cluster-tn3` |
| Rolle | `auth/kubernetes-<cluster-name>/role/mariadb` | `auth/kubernetes-cluster-tn3/role/mariadb` |

---

## Vergleich: ESO vs. VSO

| Aspekt | ESO (External Secrets Operator) | VSO (Vault Secrets Operator) |
|---|---|---|
| **Lizenz** | Apache 2.0 (CNCF-Projekt) | BSL 1.1 (HashiCorp) |
| **Provider** | Multi-Provider (Vault, AWS, Azure, GCP, …) | Nur Vault/OpenBao |
| **CRDs für diesen Use-Case** | 2 (SecretStore + ExternalSecret) | 3 (VaultConnection + VaultAuth + VaultStaticSecret) |
| **Helm Repo** | `external-secrets/external-secrets` | `hashicorp/vault-secrets-operator` |
| **Empfehlung OpenBao** | Ja, offiziell empfohlen | Funktioniert, aber BSL-Lizenz |

---

## Zusammenfassung: Datenfluss

```
Gemeinsamer OpenBao-Server (openbao.jmetzger.do.t3isp.de)
  └── secret/<cluster-name>/mariadb
        │
        ▼  (HTTPS + K8s Auth via kubernetes-<cluster-name>)
   ESO im eigenen Cluster synct alle 60s
        │
        ▼
K8s Secret (mariadb-k8s-secret)
        │
        ▼
Pod env: MARIADB_ROOT_PASSWORD (via secretKeyRef)
```

---

## Troubleshooting

| Problem | Lösung |
|---------|--------|
| `path is already in use` bei `secrets enable` | Harmlos — ein anderer TN hat `secret/` bereits aktiviert |
| `path is already in use` bei `auth enable` | Prüfen ob du den richtigen Clusternamen verwendest: `-path=kubernetes-<cluster-name>` |
| SecretStore zeigt nicht `Valid` | `kubectl describe secretstore openbao-backend` → Events prüfen |
| ExternalSecret zeigt `SyncError` | `kubectl describe externalsecret mariadb-secret` → Fehlermeldung lesen |
| Auth schlägt fehl | ServiceAccount-Name und Namespace müssen exakt mit der OpenBao-Rolle übereinstimmen |
| `permission denied` | Policy-Pfad prüfen: `secret/data/<cluster-name>/mariadb` (nicht `secret/<cluster-name>/mariadb`) |
| TLS-Fehler zum OpenBao-Server | CA-Cert im SecretStore via `caProvider` hinterlegen |
| Token-Review schlägt fehl | Prüfen ob `vault-auth` SA + ClusterRoleBinding existieren und `token_reviewer_jwt` aktuell ist |
| ESO Pods nicht ready | `kubectl logs -n external-secrets deploy/external-secrets` |

---

## Aufräumen

### Im eigenen Cluster

```bash
kubectl delete -f mariadb-deployment.yaml
kubectl delete -f external-secret.yaml
kubectl delete -f secret-store.yaml
kubectl delete -f mariadb-sa.yaml
kubectl delete secret mariadb-k8s-secret 2>/dev/null
kubectl delete -f vault-auth-token.yaml
kubectl delete clusterrolebinding vault-auth-delegator
kubectl delete serviceaccount vault-auth -n default
helm uninstall external-secrets -n external-secrets
kubectl delete namespace external-secrets
```

### Auf dem OpenBao-Server

```bash
bao auth disable kubernetes-$CLUSTER_NAME
bao policy delete mariadb-read-$CLUSTER_NAME
bao kv delete secret/$CLUSTER_NAME/mariadb
```
