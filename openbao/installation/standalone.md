# OpenBao Installation – Standalone (.deb-Paket)

## Was bereits vorhanden ist

Der Server wurde automatisch vorbereitet. Folgendes ist bereits eingerichtet:

```
Internet (443/80)
      |
   nginx (systemd)
      |  - Let's Encrypt Zertifikat via certbot
      |  - HTTP -> HTTPS Redirect
      |  - HTTPS: statische Seite "Server bereit"
```

nginx-Konfiguration unter `/etc/nginx/sites-available/openbao`:

```
server {
    listen 80;
    server_name openbao.<DEIN-NAME>.do.t3isp.de;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name openbao.<DEIN-NAME>.do.t3isp.de;

    ssl_certificate     /etc/letsencrypt/live/openbao.<DEIN-NAME>.do.t3isp.de/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/openbao.<DEIN-NAME>.do.t3isp.de/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root /var/www/openbao;
    index index.html;

    location / {
        try_files $uri $uri/ =404;    # <-- wird in Schritt 4 ersetzt
    }
}
```

Ziel nach dieser Uebung:

```
Internet (443/80)
      |
   nginx (TLS-Terminierung)
      |
   OpenBao (127.0.0.1:8200, kein eigenes TLS)
```

---

## Schritt 1: Per SSH einloggen

```
ssh <DEIN-NAME>@openbao.<DEIN-NAME>.do.t3isp.de
```

Aktuellen Zustand pruefen:

```
sudo systemctl status nginx
curl -s https://openbao.<DEIN-NAME>.do.t3isp.de | grep -o '<title>.*</title>'
```

Erwartete Ausgabe: `<title>Server bereit</title>`

---

## Schritt 2: OpenBao installieren

```
# in root wechseln
sudo su
```

```
wget https://github.com/openbao/openbao/releases/download/v2.5.1/openbao_2.5.1_linux_amd64.deb
sudo dpkg -i openbao_2.5.1_linux_amd64.deb
```

Installation pruefen:

```
bao version
```

Erwartete Ausgabe:

```
OpenBao v2.5.1 (...)
```

---

## Schritt 3: OpenBao konfigurieren & Firewall freischalten

OpenBao lauscht nur auf `127.0.0.1` – TLS wird von nginx uebernommen.

```
sudo tee /etc/openbao/openbao.hcl > /dev/null <<'EOF'
ui = true

storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  cluster_address = "10.135.0.5:8201"
  tls_disable = 1
}

api_addr = "https://openbao.tn<tln-nr>.do.t3isp.de:8200"
# Achtung: Hier Deine private IP eintragen
# Abfrage mit ip a show eth1 (digitalocean)
cluster_addr = "https://10.135.0.5:8201"
EOF
```

> `api_addr` auf die eigene Domain anpassen – sie wird fuer UI-Redirects und CLI-Ausgaben benoetigt.

# Achtung: Der Port muss in der Firewall geöffnet werden
ufw allow from 10.135.0.0/24 to 10.135.0.5 port 8201 proto tcp

# Api muss von aussen erreichbar sein (später z.B. für oidc - login notwendig  
sudo ufw allow to 10.135.0.2 port 8201 proto tcp





---

## Schritt 4: nginx auf Proxy-Modus umstellen

Der bestehende HTTPS-Block liefert bisher eine statische Seite. Der `location /`-Block
muss durch einen `proxy_pass` zu OpenBao ersetzt werden.

```
DOMAIN="openbao.<DEIN-NAME>.do.t3isp.de"
```

```
sudo tee /etc/nginx/sites-available/openbao > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:8200;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
```

Konfiguration testen und nginx neu laden:

```
sudo nginx -t
sudo systemctl reload nginx
```

---

## Schritt 5: OpenBao starten

```
sudo systemctl enable openbao
sudo systemctl start openbao
sudo systemctl status openbao
sudo journalctl -u openbao 
```

Erwartete Ausgabe (Auszug):

```
Active: active (running)
...
==> OpenBao server started! ...
```

---

## Schritt 6: Umgebungsvariable setzen

```
export BAO_ADDR='http://127.0.0.1:8200'
```

Dauerhaft speichern:

```
echo 'export BAO_ADDR="http://127.0.0.1:8200"' >> ~/.bashrc
```

Verifizieren

  * Wenn BAO_ADDR nicht richtig gesetzt oder garnicht gesetzt ist kommt ein Fehler oder keine Antwort 

```
# Letztendlich kommuniziert bao status auch über die https:// api 
bao status 
```

---

## Schritt 7: Initialisieren

```
bao operator init -key-shares=5 -key-threshold=3 -format=json | tee ~/openbao-init.json

## das ist das gleiche wie (default) 
bao operator init -format=json | tee ~/openbao-init.json

```



Die Ausgabe enthaelt 5 Unseal Keys und den Root Token – diese jetzt sichern:

```
cat ~/openbao-init.json
```

Ausgabe (Beispiel):

```
{
  "unseal_keys_b64": [
    "KEY-1",
    "KEY-2",
    "KEY-3",
    "KEY-4",
    "KEY-5"
  ],
  "root_token": "hvs.XXXXXX"
}
```

> **SICHERHEITSHINWEIS:**
> Diese Datei enthaelt hochsensible Daten. Unseal Keys und Root Token muessen
> an einem sicheren Ort ausserhalb des Servers gespeichert werden (z.B. Passwortmanager,
> verschluesseltes Laufwerk). Danach die Datei vom Server loeschen:
>
> ```
> cp ~/openbao-init.json /sicherer/ort/   # erst sichern!
> rm ~/openbao-init.json                  # dann loeschen
> ```
>
> Wer Zugriff auf diese Datei hat, hat vollen Zugriff auf OpenBao und alle gespeicherten Secrets.

---

## Schritt 8: Entsiegeln (Unseal)

OpenBao startet immer im Sealed-Zustand. Zum Entsiegeln werden 3 der 5 Keys benoetigt.

```
bao operator unseal   # Key 1 eingeben
bao operator unseal   # Key 2 eingeben
bao operator unseal   # Key 3 eingeben
```

Status pruefen:

```
bao status
```

Erwartete Ausgabe:

```
Sealed          false
Total Shares    5
Threshold       3
Version         2.5.1
```

`Sealed` muss `false` sein.

---

## Schritt 9: Anmelden

```
bao login
```

Root Token aus `~/openbao-init.json` eingeben.

Erfolgreiche Anmeldung:

```
Success! You are now authenticated.
token: hvs.XXXXXX
```

---

## Schritt 10: UI aufrufen

Im Browser oeffnen:

```
https://openbao.<DEIN-NAME>.do.t3isp.de/ui
```

Beim ersten Aufruf erscheint der Unseal-Wizard. Mit dem Root Token anmelden.

---

## Schritt 11: Ergebnis pruefen

```
curl -s https://openbao.<DEIN-NAME>.do.t3isp.de/v1/sys/health | python3 -m json.tool
```

Erwartete Ausgabe:

```
{
    "initialized": true,
    "sealed": false,
    "standby": false,
    "version": "2.5.1",
    ...
}
```

| Feld | Erwarteter Wert |
|---|---|
| `initialized` | `true` |
| `sealed` | `false` |
| `standby` | `false` |

---

## Zusammenfassung

```
Client
  |
  | HTTPS (443)
  v
nginx  <-- TLS-Terminierung mit Let's Encrypt
  |
  | HTTP (127.0.0.1:8200)
  v
OpenBao  <-- kein eigenes TLS, nur localhost
  |
  v
/opt/openbao/data  <-- File Storage
```

| Komponente | Pfad / Adresse |
|---|---|
| nginx Config | `/etc/nginx/sites-available/openbao` |
| OpenBao Config | `/etc/openbao/openbao.hcl` |
| OpenBao Data | `/opt/openbao/data` |
| Init-Output | `~/openbao-init.json` |
| Logs nginx | `journalctl -u nginx -f` |
| Logs OpenBao | `journalctl -u openbao -f` |
| API intern | `http://127.0.0.1:8200` |
| API extern | `https://openbao.<DEIN-NAME>.do.t3isp.de` |
