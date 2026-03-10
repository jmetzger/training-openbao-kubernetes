# MariaDB Deployment mit OpenBao & Vault Secrets Operator (VSO)

Schritt-für-Schritt-Anleitung: Ein Secret (`MARIADB_ROOT_PASSWORD`) wird in OpenBao gespeichert und über den VSO als natives Kubernetes Secret in den MariaDB-Pod injiziert.

---

## Voraussetzungen

- Kubernetes-Cluster (z.B. RKE2, k3s, etc.)
- OpenBao läuft auf einer dedizierten VM (`https://openbao.tn1.do.t3isp.de`)
- `bao` CLI konfiguriert und authentifiziert
- Helm v3 installiert
- Der K8s-Cluster muss die OpenBao-VM per HTTPS erreichen können

---

## Prep 1: Done by trainer: Install bao executable 

```
wget https://github.com/openbao/openbao/releases/download/v2.5.1/bao_2.5.1_Linux_x86_64.tar.gz
tar xzf bao_2.5.1_Linux_x86_64.tar.gz
sudo mv bao /usr/local/bin/
```

## Schritt 1: KV Secrets Engine aktivieren

```bash
# Kann auch in die ~/.bashrc 
export BAO_ADDR=https://openbao.tn<deine-tn-nr>.do.t3isp.de 
bao login -method=userpass username=<dein-user>
bao secrets enable -path=secret kv-v2
```

> Falls bereits aktiviert, überspringen.

---

## Schritt 2: Secret in OpenBao anlegen

```bash
bao kv put secret/mariadb root-password="meinSuperGeheimesPasswort"
```

Kontrolle:

```bash
bao kv get secret/mariadb
```

---

## Schritt 3: Policy erstellen

```
cd
mkdir -p openbao-hcl/mariadb
cd openbao-hcl/mariadb
```

```
nano mariadb-read.hcl
```

```hcl
path "secret/data/mariadb" {
  capabilities = ["read"]
}
```

Policy schreiben:

```bash
bao policy write mariadb-read mariadb-read.hcl
```

> **Hinweis:** Bei KV-v2 ist der tatsächliche Pfad immer `secret/data/<path>`, auch wenn man mit `bao kv` nur `secret/<path>` angibt.

---

## Schritt 4: Vault Secrets Operator (VSO) installieren

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system \
  --create-namespace
```

Prüfen, ob der Operator läuft:

```bash
kubectl get pods -n vault-secrets-operator-system
```

---

## Schritt 5: Kubernetes Auth Method aktivieren und konfigurieren

Da OpenBao **außerhalb** des Clusters läuft, muss es den API-Server erreichen und ServiceAccount-Tokens validieren können. Dafür braucht es explizit:

- `kubernetes_host` — API-Server-Adresse (von außen erreichbar)
- `kubernetes_ca_cert` — CA-Zertifikat des Clusters
- `token_reviewer_jwt` — ein langlebiger Token mit `system:auth-delegator`-Berechtigung

### 5a: ServiceAccount und ClusterRoleBinding für Token-Review anlegen (im Cluster)

> **Wichtig:** Dieser Schritt muss **vor** dem Aktivieren der Auth Method erfolgen, da OpenBao für die Token-Validierung einen gültigen `token_reviewer_jwt` benötigt.

```bash
kubectl create serviceaccount vault-auth -n default

kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=default:vault-auth
```

### 5b: Langlebigen Token erzeugen

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

### 5d: Auth Method in OpenBao aktivieren

```bash
bao auth enable kubernetes
```

### 5e: OpenBao konfigurieren (auf der VM)

```bash
bao write auth/kubernetes/config \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA_CERT" \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT"
```

> **Wichtig:** `kubernetes_host` muss die **externe** Adresse des API-Servers sein, die von der OpenBao-VM aus erreichbar ist — nicht `https://kubernetes.default.svc:443`.

### 5f: Rolle anlegen

```bash
bao write auth/kubernetes/role/mariadb \
  bound_service_account_names=mariadb-sa \
  bound_service_account_namespaces=default \
  policies=mariadb-read \
  ttl=1h
```

---

## Schritt 6: VaultConnection erstellen

```yaml
# vault-connection.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: openbao
  namespace: default
spec:
  address: https://openbao.tn1.do.t3isp.de
```

> Falls OpenBao ein selbstsigniertes Zertifikat nutzt, muss `spec.caCertSecretRef` auf ein K8s Secret mit dem CA-Cert gesetzt werden.

```bash
kubectl apply -f vault-connection.yaml
```

---

## Schritt 7: ServiceAccount anlegen

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

## Schritt 8: VaultAuth erstellen

```yaml
# vault-auth.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: default
  namespace: default
spec:
  vaultConnectionRef: openbao
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: mariadb
    serviceAccount: mariadb-sa
```

```bash
kubectl apply -f vault-auth.yaml
```

---

## Schritt 9: VaultStaticSecret erstellen

```yaml
# vault-static-secret.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: mariadb-secret
  namespace: default
spec:
  vaultAuthRef: default
  mount: secret
  path: mariadb
  type: kv-v2
  refreshAfter: 60s
  destination:
    name: mariadb-k8s-secret
    create: true
```

```bash
kubectl apply -f vault-static-secret.yaml
```

Prüfen, ob das Kubernetes Secret erstellt wurde:

```bash
kubectl get secret mariadb-k8s-secret -o yaml
```

---

## Schritt 10: MariaDB Deployment ausrollen

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

## Schritt 11: Verifizieren

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

## Zusammenfassung: Datenfluss

```
OpenBao VM (openbao.tn1.do.t3isp.de)
  └── secret/mariadb
        │
        ▼  (HTTPS)
   VSO im Cluster synct alle 60s
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
| Secret wird nicht erstellt | `kubectl describe vaultstaticsecret mariadb-secret` → Events prüfen |
| Auth schlägt fehl | ServiceAccount-Name und Namespace müssen exakt mit der OpenBao-Rolle übereinstimmen |
| `permission denied` | Policy-Pfad prüfen: `secret/data/mariadb` (nicht `secret/mariadb`) |
| TLS-Fehler zur VM | CA-Cert in `VaultConnection` via `caCertSecretRef` hinterlegen |
| Token-Review schlägt fehl | Prüfen ob `vault-auth` SA + ClusterRoleBinding existieren und `token_reviewer_jwt` aktuell ist |
| VSO Pods nicht ready | `kubectl logs -n vault-secrets-operator-system deploy/vault-secrets-operator-controller-manager` |
