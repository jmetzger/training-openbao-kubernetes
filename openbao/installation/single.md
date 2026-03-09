# OpenBao Installation auf Debian (deb-Paket) – hinter nginx Reverse Proxy

> **Voraussetzung:** nginx läuft bereits als Reverse Proxy mit Let's Encrypt.
> **Version:** OpenBao v2.5.1 (aktuell, Stand März 2026)

---

## 1. Paket herunterladen und installieren

```bash
wget https://github.com/openbao/openbao/releases/download/v2.5.1/bao_2.5.1_linux_amd64.deb
sudo dpkg -i bao_2.5.1_linux_amd64.deb
sudo apt-get install -f   # ggf. fehlende Abhängigkeiten nachziehen
```

Prüfen:

```bash
bao version
```

## 2. OpenBao konfigurieren (TLS deaktiviert)

Da TLS von nginx terminiert wird, lauscht OpenBao nur auf `127.0.0.1` ohne eigenes TLS.

Das selbst-signierte Zertifikat, das bei der Installation automatisch erzeugt wird, kann ignoriert werden.

```bash
sudo tee /etc/openbao/openbao.hcl > /dev/null <<'EOF'
ui = true

storage "file" {
  path = "/opt/openbao/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

# Optional: API-Adresse für CLI und UI-Redirects
api_addr = "https://bao.example.com"
EOF
```

> **Hinweis:** `api_addr` auf deine tatsächliche Domain anpassen, die nginx mit Let's Encrypt absichert.

## 3. Systemd-Service aktivieren und starten

```bash
sudo systemctl enable openbao
sudo systemctl start openbao
sudo systemctl status openbao
```

## 4. Umgebungsvariable setzen

```bash
export BAO_ADDR='http://127.0.0.1:8200'
```

Für dauerhaftes Setzen:

```bash
echo 'export BAO_ADDR="http://127.0.0.1:8200"' >> ~/.bashrc
```

## 5. Initialisieren und Entsiegeln

```bash
bao operator init -key-shares=5 -key-threshold=3 -format=json > ~/openbao-init.json
```

**Unseal Keys und Root Token sicher aufbewahren!**

Dreimal entsiegeln (jeweils mit unterschiedlichem Key):

```bash
bao operator unseal   # Key 1
bao operator unseal   # Key 2
bao operator unseal   # Key 3
```

Status prüfen:

```bash
bao status
```

`Sealed` muss `false` sein.

## 6. Anmelden

```bash
bao login   # Root Token eingeben
```

## 7. nginx Reverse Proxy Konfiguration

Neue Site-Konfiguration anlegen:

```bash
sudo tee /etc/nginx/sites-available/openbao > /dev/null <<'NGINX'
server {
    listen 443 ssl;
    server_name bao.example.com;

    ssl_certificate     /etc/letsencrypt/live/bao.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bao.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name bao.example.com;
    return 301 https://$host$request_uri;
}
NGINX
```

Aktivieren:

```bash
sudo ln -s /etc/nginx/sites-available/openbao /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## 8. Let's Encrypt Zertifikat (falls noch nicht vorhanden)

```bash
sudo certbot --nginx -d bao.example.com
```

## 9. Post-Installation Hardening

- **Swap deaktivieren oder verschlüsseln** – OpenBao-Secrets könnten sonst auf Disk landen
- **Root Token revoken** nach Ersteinrichtung: `bao token revoke <root-token>`
- **Audit-Logging aktivieren:** `bao audit enable file file_path=/var/log/openbao/audit.log`
- **Firewall:** Port 8200 nur auf `127.0.0.1` belassen (ist per Config bereits so)

---

## Zusammenfassung Architektur

```
Client → HTTPS (443) → nginx (Let's Encrypt TLS) → HTTP (127.0.0.1:8200) → OpenBao
```

TLS wird ausschließlich von nginx terminiert. OpenBao selbst läuft ohne TLS auf localhost.
