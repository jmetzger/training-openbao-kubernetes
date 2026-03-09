# destroy-openbao-single.sh – Usage Guide

Löscht Droplets und DNS-Records, die per `install-openbao-single.sh` erstellt wurden.

---

## Voraussetzungen

- `.env` mit `DIGITALOCEAN_ACCESS_TOKEN` im Projekt-Root vorhanden
- `doctl` installiert (wird automatisch installiert falls nicht vorhanden)

---

## Aufruf-Modi

### Eigenen Server löschen

```bash
./destroy-openbao-single.sh
```

Löscht `openbao-$USER` und den DNS-Record `openbao.$USER.do.t3isp.de`.

---

### N Trainings-Server löschen

```bash
./destroy-openbao-single.sh 5
```

Löscht `openbao-tln1` … `openbao-tln5` sowie die zugehörigen DNS-Records. Entspricht dem Multi-Server-Modus von `install-openbao-single.sh`.

---

### Alle openbao-Droplets löschen

```bash
./destroy-openbao-single.sh all
```

Löscht **alle** Droplets mit dem Prefix `openbao-` im DigitalOcean-Account sowie ihre DNS-Records.

> **Achtung:** Diese Aktion ist nicht rückgängig zu machen. Alle Droplets mit dem Prefix `openbao-` werden gelöscht.

---

## Ablauf

1. `.env` laden und `DIGITALOCEAN_ACCESS_TOKEN` validieren
2. Zu löschende Droplets ermitteln (je nach Modus)
3. Bestätigung anzeigen – zeigt Liste aller zu löschenden Droplets:
   ```
   Folgende Droplets werden gelöscht:
     - openbao-tln1  (DNS: openbao.tln1.do.t3isp.de)
     - openbao-tln2  (DNS: openbao.tln2.do.t3isp.de)

   Wirklich löschen? [y/N]
   ```
4. Droplets und DNS-Records **parallel** löschen
5. Gesamtübersicht ausgeben

---

## Beispielausgaben

### Erfolg

```
══════════════════════════════════════════════════
         DESTROY-ÜBERSICHT
══════════════════════════════════════════════════
  tln1  ✓  Droplet gelöscht, DNS-Record entfernt
  tln2  ✓  Droplet gelöscht, DNS-Record entfernt
══════════════════════════════════════════════════
```

### Droplet bereits gelöscht

```
══════════════════════════════════════════════════
         DESTROY-ÜBERSICHT
══════════════════════════════════════════════════
  tln1  ✓  Droplet gelöscht, DNS-Record entfernt
  tln3  ✗  Droplet nicht gefunden (bereits gelöscht?)
══════════════════════════════════════════════════
```

---

## Exit-Codes

| Code | Bedeutung |
|------|-----------|
| `0`  | Alles gelöscht (oder nicht vorhanden) |
| `1`  | Mindestens ein API-Fehler beim Löschen |

---

## Troubleshooting

### `FEHLER: doctl Authentifizierung fehlgeschlagen`

Token in `.env` prüfen:
```bash
cat .env | grep DIGITALOCEAN_ACCESS_TOKEN
doctl account get
```

### DNS-Record wurde nicht entfernt

DNS-Records manuell prüfen und löschen:
```bash
doctl compute domain records list do.t3isp.de
doctl compute domain records delete do.t3isp.de <RECORD_ID> --force
```

### Droplet bleibt nach Fehler bestehen

Droplet manuell löschen:
```bash
doctl compute droplet list
doctl compute droplet delete <DROPLET_ID> --force
```
