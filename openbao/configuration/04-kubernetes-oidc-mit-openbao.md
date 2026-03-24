# Lab: OIDC-Authentifizierung für kubectl mit OpenBao

## Ziel

In dieser Übung konfigurierst du OpenBao als OIDC Identity Provider und richtest deinen Kubernetes-Cluster so ein, dass sich Benutzer per Browser-Login über OpenBao bei kubectl authentifizieren.

**Architektur:**

```
kubectl → kubelogin (öffnet Browser)
              ↓
         OpenBao (OIDC Provider)
              ↓ (ID Token)
         kube-apiserver (validiert Token)
```

## Voraussetzungen

- Zugang zum gemeinsamen OpenBao-Server: `https://openbao.jmetzger.do.t3isp.de`
- Ein eigener kubeadm-Cluster mit SSH-Zugriff auf die Control Plane Node
- `bao` CLI installiert und `VAULT_ADDR` / `BAO_ADDR` gesetzt
- Root-Token oder Admin-Zugriff auf OpenBao
- `kubectl` und `krew` installiert

> **Namenskonvention:** Ersetze `XX` überall durch deine Teilnehmernummer (z.B. `1`, `2`, ...).

---

## Schritt 1: Bei OpenBao einloggen und User anlegen

Logge dich mit deinem Admin-Token bei OpenBao ein:

```bash
export BAO_ADDR="https://openbao.jmetzger.do.t3isp.de"
bao login -method=userpass username=admin
```

Aktiviere die Userpass-Auth-Methode (falls noch nicht geschehen – ignoriere den Fehler, falls sie schon aktiv ist):

```bash
bao auth enable userpass 2>/dev/null || echo "userpass bereits aktiviert"
```

Erstelle deinen persönlichen User:

```
# Anpassen
TN=1
```

```bash
bao write auth/userpass/users/tln$TN password="training"
```

**Wichtig:** Logge dich einmal als dein User ein, damit OpenBao eine Identity-Entity anlegt. Ohne Entity funktioniert OIDC nicht:

```bash
bao login -method=userpass username=tln$TN password="training"
```

Notiere dir die Entity-ID aus dem Login-Output (Feld `entity_id`). Falls du sie verpasst hast:

```bash
bao token lookup -format=json | jq -r '.data.entity_id'
```

```bash
# Hier notieren:
# ENTITY_ID=___________________________
```

Logge dich danach wieder als Admin ein:

```bash
bao login -method=userpass username=admin
```

---

## Schritt 2: OIDC Key erstellen

Jeder Teilnehmer erstellt seinen eigenen Signing Key:
Das ist das private/public key - Schlüsselpaar 
(zum Signieren / Validieren)


```bash
# das musst du ändern
TN=1
```


```bash
bao write identity/oidc/key/key-tln$TN \
  allowed_client_ids="*" \
  rotation_period="24h" \
  verification_ttl="24h" \
  algorithm="RS256"
```

---

## Schritt 3: OIDC Scope definieren



Damit der kube-apiserver einen brauchbaren Username aus dem ID Token lesen kann, definieren wir einen Scope mit einem `username`-Claim:

```bash
bao write identity/oidc/scope/user \
  template='{"username":{{identity.entity.name}}}'
```

> **Hinweis:** Dieser Scope ist für alle Teilnehmer identisch — `{{identity.entity.name}}` wird erst zur Laufzeit pro User aufgelöst. Falls ein anderer Teilnehmer den Scope schon angelegt hat, überschreibt der Befehl ihn mit dem gleichen Inhalt.

> **Hintergrund: Warum brauchen wir einen Scope?**
>
> Ohne eigenen Scope enthält das ID Token nur Standardfelder:
>
> ```json
> {
>   "iss": "https://openbao.jmetzger.do.t3isp.de/v1/identity/oidc/provider/provider1",
>   "sub": "f3d2a1b7-4e5c-6d8f-9a0b-1c2d3e4f5a6b",
>   "aud": "abc123...",
>   "exp": 1711324800
> }
> ```
>
> Das `sub`-Claim ist die **Entity-UUID** — eine kryptische ID. Dein RBAC müsste dann so aussehen:
> `--user="oidc:f3d2a1b7-4e5c-6d8f-9a0b-1c2d3e4f5a6b"` — unpraktisch.
>
> Mit dem Scope-Template sagen wir OpenBao: *"Pack den Entity-Namen als Extra-Feld ins Token."*
> Das Token sieht dann so aus:
>
> ```json
> {
>   "iss": "...",
>   "sub": "f3d2a1b7-4e5c-6d8f-9a0b-1c2d3e4f5a6b",
>   "aud": "abc123...",
>   "exp": 1711324800,
>   "username": "tln1"
> }
> ```
>
> In Schritt 6 sagen wir dem kube-apiserver dann `--oidc-username-claim=username`, und Kubernetes sieht den User als `oidc:tln1`.
> (jedes Feld ist ein claim, so auch username, ein zusätzliches Feld)
>
> **Zusammenhang der Teile:**
> - **Scope-Template** → Steuert, welche Extra-Claims im Token landen
> - **Provider** → `scopes_supported="user"` aktiviert den Scope
> - **kube-apiserver** → `--oidc-username-claim=username` liest genau dieses Feld

---

## Schritt 4: OIDC Client registrieren

Der OIDC Client repräsentiert dein Kubernetes-Cluster als "Relying Party":

```bash
bao write identity/oidc/client/kubernetesXX \
  redirect_uris="http://localhost:8000/callback" \
  assignments="allow_all" \
  key="keyXX" \
  id_token_ttl="1h" \
  access_token_ttl="1h"
```

Client-Credentials auslesen und notieren:

```bash
bao read identity/oidc/client/kubernetesXX
```

```bash
# Hier notieren:
# CLIENT_ID=___________________________
# CLIENT_SECRET=___________________________
```

---

## Schritt 5: OIDC Provider konfigurieren

Jeder Teilnehmer erstellt seinen eigenen Provider:

```bash
bao write identity/oidc/provider/providerXX \
  allowed_client_ids="$(bao read -field=client_id identity/oidc/client/kubernetesXX)" \
  scopes_supported="user"
```

Teste, ob der Discovery-Endpoint erreichbar ist:

```bash
curl -s $BAO_ADDR/v1/identity/oidc/provider/providerXX/.well-known/openid-configuration | jq .
```

Du solltest ein JSON mit `issuer`, `authorization_endpoint`, `token_endpoint` etc. sehen.

---

## Schritt 6: kube-apiserver konfigurieren

Jetzt wechseln wir zum Kubernetes-Cluster. Verbinde dich per SSH auf die Control Plane Node:

```bash
ssh root@DEINE_CONTROL_PLANE_NODE
```

### 6a: kube-apiserver-Manifest editieren

Bearbeite `/etc/kubernetes/manifests/kube-apiserver.yaml` und füge folgende Flags zum `command`-Block hinzu:

```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Ergänze unter `spec.containers[0].command`:

```yaml
    - --oidc-issuer-url=https://openbao.jmetzger.do.t3isp.de/v1/identity/oidc/provider/providerXX
    - --oidc-client-id=CLIENT_ID
    - --oidc-username-claim=username
    - --oidc-username-prefix=oidc:
```

> **Wichtig:**
> - Ersetze `CLIENT_ID` durch deine Client-ID aus Schritt 4.
> - `--oidc-username-claim=username` passt zum Scope-Template aus Schritt 3.

### 6b: Neustart abwarten

Der kube-apiserver wird automatisch von kubelet neu gestartet, weil das Manifest ein Static Pod ist. Warte kurz und prüfe:

```bash
# API-Server-Pod beobachten
crictl ps | grep kube-apiserver

# Oder prüfen, ob die API erreichbar ist
kubectl get nodes
```

Falls der API-Server nicht startet, prüfe die Logs:

```bash
crictl logs $(crictl ps -a --name kube-apiserver -q | head -1)
```

> **Typische Fehler:**
> - `oidc-issuer-url` nicht erreichbar → Firewall/DNS prüfen
> - YAML-Syntax-Fehler → Einrückung prüfen

---

## Schritt 7: RBAC einrichten

Zurück auf deinem Arbeitsrechner (mit kubeadm-Admin-Zugriff):

```bash
kubectl create clusterrolebinding oidc-tlnXX \
  --clusterrole=cluster-admin \
  --user="oidc:tlnXX"
```

> Der Username setzt sich zusammen aus dem Prefix `oidc:` (aus `--oidc-username-prefix`) und dem Wert des `username`-Claims im Token (`tlnXX`).

---

## Schritt 8: kubelogin installieren und testen

### 8a: Plugin installieren

```bash
kubectl krew install oidc-login
```

### 8b: Setup testen

Teste den OIDC-Flow einmal manuell:

```bash
kubectl oidc-login setup \
  --oidc-issuer-url=https://openbao.jmetzger.do.t3isp.de/v1/identity/oidc/provider/providerXX \
  --oidc-client-id=CLIENT_ID \
  --oidc-client-secret=CLIENT_SECRET
```

Der Browser öffnet sich, du loggst dich mit `tlnXX` / `training` ein. Danach zeigt kubelogin die Claims des ID Tokens an. Prüfe, ob der `username`-Claim korrekt ist.

### 8c: kubeconfig einrichten

```bash
# Neuen User in kubeconfig anlegen
kubectl config set-credentials oidc-tlnXX \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://openbao.jmetzger.do.t3isp.de/v1/identity/oidc/provider/providerXX \
  --exec-arg=--oidc-client-id=CLIENT_ID \
  --exec-arg=--oidc-client-secret=CLIENT_SECRET

# Neuen Context anlegen
kubectl config set-context oidc \
  --cluster=$(kubectl config view -o jsonpath='{.clusters[0].name}') \
  --user=oidc-tlnXX

# Context wechseln
kubectl config use-context oidc
```

---

## Schritt 9: Testen

```bash
# Erster Aufruf → Browser öffnet sich → Login bei OpenBao
kubectl get nodes

# Wer bin ich?
kubectl auth whoami
# Erwartete Ausgabe: oidc:tlnXX
```

Wenn `kubectl get nodes` funktioniert: **Herzlichen Glückwunsch! 🎉**

### Token-Cache leeren (bei Problemen)

```bash
kubectl oidc-login clean
```

---

## Schritt 10: Aufräumen

Zurück zum Admin-Context:

```bash
kubectl config use-context <DEIN_ADMIN_CONTEXT>
```

Optional – OpenBao-Ressourcen aufräumen:

```bash
bao delete identity/oidc/provider/providerXX
bao delete identity/oidc/client/kubernetesXX
bao delete identity/oidc/key/keyXX
bao delete auth/userpass/users/tlnXX
# Den gemeinsamen Scope "user" NICHT löschen — wird von anderen Teilnehmern genutzt
```

kube-apiserver OIDC-Flags aus dem Manifest entfernen und ClusterRoleBinding löschen:

```bash
kubectl delete clusterrolebinding oidc-tlnXX
```

---

## Zusammenfassung

| Komponente | Rolle |
|---|---|
| **OpenBao** | OIDC Identity Provider – stellt ID Tokens aus |
| **userpass** | Auth-Methode – Teilnehmer loggen sich mit Username/Passwort ein |
| **OIDC Client** | Repräsentiert das Kubernetes-Cluster |
| **OIDC Provider** | Stellt Discovery-Endpoint + Token-Endpoint bereit |
| **kubelogin** | kubectl-Plugin – übernimmt den Browser-Login-Flow |
| **kube-apiserver** | Validiert das ID Token gegen den OIDC Issuer |
| **RBAC** | Bindet den OIDC-Username an Kubernetes-Rollen |

---

## Bonus: Was passiert unter der Haube?

1. Du rufst `kubectl get nodes` auf
2. kubectl erkennt den `exec`-Block in der kubeconfig und startet `kubelogin`
3. kubelogin prüft den Token-Cache – ist ein gültiges Token vorhanden, wird es direkt verwendet
4. Falls nicht: kubelogin öffnet den Browser auf `https://openbao.jmetzger.do.t3isp.de/v1/identity/oidc/provider/providerXX/authorize?...`
5. Du loggst dich bei OpenBao ein (userpass)
6. OpenBao leitet zurück auf `http://localhost:8000/callback` mit einem Authorization Code
7. kubelogin tauscht den Code gegen ein ID Token
8. kubelogin gibt das ID Token an kubectl zurück
9. kubectl sendet das Token als `Authorization: Bearer <ID_TOKEN>` an den kube-apiserver
10. kube-apiserver validiert die Signatur über den JWKS-Endpoint des Providers
11. kube-apiserver extrahiert `username` und wendet den Prefix `oidc:` an
12. RBAC prüft die Berechtigung für `oidc:tlnXX`
