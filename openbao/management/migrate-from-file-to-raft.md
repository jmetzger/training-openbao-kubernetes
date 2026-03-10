# Übung: OpenBao Storage Migration — File → Raft

#### 2026-03-10 Achtung: Funktioniert nicht, der Openbao - Server kann mit den migrierten Daten nicht gestartet werden, nach dem unseal, springt er wieder auf seal 


## Voraussetzungen

- OpenBao läuft aktuell mit `storage "file"`
- Zugriff als root auf den Server
- Unseal Keys sind vorhanden

## Schritt 1: Aktuelle Config prüfen

```bash
cat /etc/openbao/openbao.hcl | grep -A5 storage
```

Erwartete Ausgabe (Beispiel):

```hcl
storage "file" {
  path = "/opt/openbao/data"
}
```

> Den `path` merken — er wird in der Migrations-Config als Quelle gebraucht.

## Schritt 2: Backup des aktuellen Data-Dirs

```bash
# Sicherheitskopie VOR der Migration
tar czf /backup/openbao-pre-migration-$(date +%Y%m%d).tar.gz /opt/openbao/data/
```

## Schritt 3: OpenBao stoppen

```bash
systemctl stop openbao

# Prüfen, dass es wirklich gestoppt ist
systemctl status openbao
```

> **Wichtig:** OpenBao muss gestoppt sein. Die Migration darf nicht im laufenden Betrieb passieren.

## Schritt 4: Zielverzeichnis anlegen

```bash
mkdir -p /opt/openbao/data-raft
chown openbao:openbao /opt/openbao/data-raft
```

## Schritt 5: Migrations-Config erstellen

```bash
cat > /etc/openbao/migrate.hcl <<'EOF'
storage_source "file" {
  path = "/opt/openbao/data"
}

storage_destination "raft" {
  path    = "/opt/openbao/data-raft"
  node_id = "node1"
}
api_addr = "https://openbao.tn1.do.t3isp.de:8200"
# mit ip a interne ip ausfinding machen 
cluster_addr = "http://10.135.0.5:8201"
EOF
```

```
# Achtung: Der Port muss in der Firewall geöffnet werden
ufw allow from 10.135.0.0/24 to 10.135.0.5 port 8201 proto tcp
```


> Diese Config wird **nur** vom `migrate`-Befehl gelesen — nicht von OpenBao selbst.
> Der Pfad `data-raft` ist bewusst gewählt, damit er während der Migration nicht mit dem alten `data`-Dir kollidiert. Am Ende wird er auf `/opt/openbao/data` umbenannt.

## Schritt 6: Migration durchführen

```bash
bao operator migrate -config=/etc/openbao/migrate.hcl
# Rechte setzen
chown -R openbao:openbao /opt/openbao/data-raft/*

cd /opt/openbao/
mv data data-file-bkup
mv data-raft data 

```

Erwartete Ausgabe bei Erfolg:

```
Success! All of the keys have been migrated.
```

## Schritt 7: Hauptconfig auf Raft umstellen

```bash
# Backup der alten Config
cp -a /etc/openbao/openbao.hcl /etc/openbao/openbao.hcl.bak
```

In `/etc/openbao/config.hcl` den Storage-Block ändern:

```hcl
# ALT:
# storage "file" {
#   path = "/opt/openbao/data"
# }

# NEU:
storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "node1"
}

# wird für raft gebraucht 
cluster_addr = "https://openbao.tn<tn-nr>.do.t3isp.de:8201"
api_addr     = "https://openbao.tn<tn-nr>.do.t3isp.de:8200"
```

## Schritt 8: OpenBao starten und unsealen

```bash
systemctl start openbao

# Mit den ALTEN Unseal Keys entsperren
bao operator unseal <key>
```

> Die Unseal Keys und der Root-Token bleiben nach der Migration erhalten.

## Schritt 9: Prüfen, ob Raft aktiv ist

```bash
# Als root einloggen
bao login

# Raft-Status prüfen
bao operator raft list-peers
```

Erwartete Ausgabe:

```
Node     Address             State     Voter
----     -------             -----     -----
node1    127.0.0.1:8201      leader    true
```

## Schritt 10: Secrets stichprobenartig prüfen

```bash
# Beispiel: Ein bekanntes Secret lesen
bao kv get secret/mein-test-secret
```

> Wenn die Daten da sind, war die Migration erfolgreich.

---

## Danach möglich

Nach der Raft-Migration kannst du:

- Weitere Nodes mit `bao operator raft join` hinzufügen
- Backups über `bao operator raft snapshot save` machen (statt Data-Dir kopieren)
- Ein HA-Cluster (3 oder 5 Nodes) aufbauen

## Aufräumen: Standard-Pfad wiederherstellen

```bash
# OpenBao stoppen
systemctl stop openbao

# Altes File-Dir entfernen, Raft-Dir auf Standard-Pfad umbenennen
rm -rf /opt/openbao/data
mv /opt/openbao/data-raft /opt/openbao/data

# Migrations-Config entfernen
rm /etc/openbao/migrate.hcl
```

In `/etc/openbao/config.hcl` den Pfad anpassen:

```hcl
storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "node1"
}
```

```bash
# OpenBao starten und unsealen
systemctl start openbao
bao operator unseal <key>
```
