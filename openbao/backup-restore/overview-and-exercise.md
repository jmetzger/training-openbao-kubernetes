# OpenBao Backup & Restore (Raft Storage)

## Backup erstellen

```bash
# Snapshot im laufenden Betrieb erstellen (Node muss unsealed sein)
bao operator raft snapshot save backup.snap
```

- Erzeugt ein **konsistentes, verschlüsseltes** Snapshot-File
- Kein Stoppen des Nodes nötig
- Besser als rohes `cp -r` des Data-Dirs (Konsistenzprobleme bei laufendem Betrieb)

## Minimale Berechtigungen (Policy)

### Nur Backup

```hcl
# backup-policy.hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
```

### Backup + Restore

```hcl
# backup-restore-policy.hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read", "update"]
}
```

### Policy und Token einrichten

```bash
# Policy erstellen
bao policy write backup-policy backup-policy.hcl

# Dediziertes periodic Token erzeugen (muss regelmäßig renewed werden)
bao token create -policy=backup-policy -period=768h -display-name="backup-token"
```

> **Tipp:** Ein periodic Token (`-period`) hat keinen festen `max_ttl`. Es läuft nach der Period (hier 768h = 32 Tage) ab, aber jedes `renew` setzt den Timer auf die volle Period zurück. Der Backup-Cronjob übernimmt das Renewal gleich mit (`renew -self`).

## Restore auf laufendem Cluster

```bash
# Node muss laufen und unsealed sein
bao operator raft snapshot restore backup.snap
```

- Nach dem Restore muss der Node **erneut unsealed** werden
- Verwendet die **gleichen Unseal Keys** wie beim Original

## Restore auf neuem / uninitialisierten Node (Disaster Recovery)

```bash
# 1. OpenBao mit gleicher Config starten
# 2. NICHT "bao operator init" ausführen!
# 3. Force-Restore auf uninitialisierten Node:
bao operator raft snapshot restore -force backup.snap

# 4. Mit den ALTEN Unseal Keys entsperren:
bao operator unseal <key>
```

## Voraussetzungen für einen erfolgreichen Restore

| Was wird benötigt?            | Beschreibung                                      |
|-------------------------------|---------------------------------------------------|
| Snapshot-File (`backup.snap`) | Erstellt mit `raft snapshot save`                  |
| Unseal Keys                   | Oder bei Auto-Unseal: Zugang zum KMS/Transit-Key   |
| OpenBao-Konfiguration         | Gleiche Config wie beim Original-Node              |

## Warum nicht einfach den Data-Ordner kopieren?

- Während OpenBao läuft, kann ein `cp -r` **inkonsistente Daten** liefern
- Der Snapshot-Mechanismus garantiert einen **konsistenten Zustand**
- Die Daten im Ordner sind verschlüsselt — ohne Unseal Keys nutzlos

## Verfügbarkeit während des Restores

Nach einem Restore ist der Node **sealed** — alle API-Anfragen werden mit **503 Service Unavailable** beantwortet (außer `sys/seal-status` und `sys/unseal`).

### Auswirkungen auf aktive Nutzer

| Bereich                        | Auswirkung                                                  |
|--------------------------------|-------------------------------------------------------------|
| Secret-Abfragen                | Schlagen sofort fehl                                        |
| Token-Validierung              | Nicht möglich → Clients verlieren Zugriff                   |
| Lease Renewals                 | Fehlgeschlagen → dynamische Secrets können ablaufen          |
| Vault Agent Injector / CSI     | Keine neuen Secrets, bereits injizierte bleiben erhalten     |
| Kubernetes Auth                | Login nicht möglich bis Node wieder unsealed                 |

### Empfehlungen für Produktion

- **Multi-Node Raft Cluster (3/5 Nodes):** Der Restore wird über den Leader an alle Nodes repliziert. Die Unterbrechung ist minimal, da der Cluster als Ganzes arbeitet.
- **Single-Node-Setup:** Wartungsfenster einplanen — es gibt keine Redundanz.
- **Auto-Unseal (Transit/KMS):** Minimiert Downtime erheblich, da der Node sich nach dem Restore **selbst entsperrt** — kein manuelles Eingreifen nötig.
- **Restore auf frischem Node:** Alternativ auf einem neuen Node recovern und diesen dem bestehenden Cluster hinzufügen — kein Impact auf laufende Clients.

## Automatisiertes Backup (Cronjob-Beispiel)

```bash
# /etc/cron.d/openbao-backup
# Token-Renewal + Snapshot in einem Job
0 2 * * * root VAULT_ADDR=https://127.0.0.1:8200 VAULT_TOKEN=$(cat /root/.bao-token) \
  bao token renew -self && \
  bao operator raft snapshot save /backup/openbao-$(date +\%Y\%m\%d).snap
```

> **Hinweis:** Snapshot-Files und Unseal Keys sollten **getrennt** aufbewahrt werden.
> Wer beides hat, hat vollen Zugriff auf alle Secrets.

---

## Übung: Backup-Token einrichten und Restore durchführen

### Teil 1: Backup-Policy und Token erstellen

```bash
# Als root einloggen - root-token raussuchen
cd
mkdir -p ~/openbao-hcl 
bao login

# Policy-Datei erstellen
cat > ~/openbao-hcl/backup-policy.hcl <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

# Policy hochladen
bao policy write backup ~/openbao-hcl/backup-policy.hcl

# Backup-Token erstellen (periodic, 32 Tage TTL)
bao token create -policy=backup -period=768h -display-name="backup-token"
```

> Den ausgegebenen Token sicher abspeichern, z.B. in `/root/.bao-backup-token`.
> Dieses Token kann **nur** Snapshots lesen — kein Zugriff auf Secrets.

### Teil 2: Backup durchführen

```bash
# Mit dem Backup-Token ein Snapshot erstellen
VAULT_TOKEN=$(cat /root/.bao-backup-token) \
  bao operator raft snapshot save /backup/openbao-$(date +%Y%m%d).snap
```

### Teil 3: Restore durchführen

```bash
# Als root einloggen — Restore ist eine Admin-Aufgabe
bao login

# Snapshot zurückspielen
bao operator raft snapshot restore /backup/openbao-20250310.snap

# Nach dem Restore: Node ist sealed → erneut unsealen
bao operator unseal <key>
```

> **Warum root für Restore?**
> Restore ist ein manueller Disaster-Recovery-Vorgang, der den gesamten Cluster-Zustand überschreibt.
> Das gehört in Admin-Hände — ein eingeschränktes Backup-Token reicht hier bewusst nicht.
