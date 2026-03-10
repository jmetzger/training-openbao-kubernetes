# OpenBao Userpass Setup mit Gruppenbasierter Rechtevergabe

## 1. Userpass Auth-Methode aktivieren (als Nutzer mit root-token) 

  * in unserem Fall root

```bash
sudo su -
env | grep BAO_ADDR
# Ansonsten setzen
# export BAO_ADDR=http://127.0.0.1:8200

```

```bash
bao auth enable userpass
```

<img width="1799" height="526" alt="image" src="https://github.com/user-attachments/assets/4eb7b2ae-6b47-4dc1-913c-2f319d317e6a" />


## 2. Prüfen ob gemountet

```bash
bao auth list
```

Erwartete Ausgabe: `userpass/` mit Typ `userpass`.

<img width="1326" height="182" alt="image" src="https://github.com/user-attachments/assets/3db71117-c2b4-4437-a8fa-9a0955daf316" />


## 3. Admin-Policy erstellen

```
nano admin-policy.hcl
```

```hcl
# Day-2-Day - Admins - Teams bis 10 Personen
# Kein unterschiedliche Admin-Rollen 
# Secrets verwalten
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# User verwalten (alle Auth-Methoden)
path "auth/userpass/users/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Policies verwalten
path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Identity (Entities, Gruppen)
path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Secrets Engines mounten/verwalten
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Auth-Methoden mounten/verwalten
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# System-Status lesen
path "sys/health" {
  capabilities = ["read"]
}

# Audit lesen (nicht ändern)
path "sys/audit" {
  capabilities = ["read"]
}

# Leases verwalten (Secrets widerrufen)
path "sys/leases/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Eigenes Token verwalten
path "auth/token/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

```

Policy hochladen:

```bash
bao policy write admin-policy admin-policy.hcl
```

## 4. User mit Zufallspasswort anlegen

```bash
TEMP_PW=$(openssl rand -base64 16)
bao write auth/userpass/users/jochen \
    password="$TEMP_PW" \
    token_ttl="1h" \
    token_max_ttl="4h"
echo "Initiales Passwort: $TEMP_PW"
```

## 5. Identity-Gruppe erstellen und Admin-Policy zuweisen

```bash
bao write identity/group \
    name="admins" \
    policies="admin-policy" \
    type="internal"
```

## 6. Auth-Accessor ermitteln

```bash
bao auth list -detailed
```

Den `accessor` Wert von `userpass/` notieren (z.B. `auth_userpass_abc123`).

## 7. Entity für den User anlegen

```bash
bao write identity/entity name="jochen"
```

Die `id` aus der Ausgabe notieren.

> **Hinweis:** Alternativ entsteht die Entity automatisch beim ersten Login. Danach die ID mit `bao read identity/entity/name/jochen` abfragen.

## 8. Entity-Alias verknüpfen

Verbindet die Entity mit dem Userpass-Account:

```bash
bao write identity/entity-alias \
    name="jochen" \
    canonical_id="<ENTITY_ID>" \
    mount_accessor="<USERPASS_ACCESSOR>"
```

## 9. User zur Gruppe hinzufügen

```bash
bao write identity/group \
    name="admins" \
    policies="admin-policy" \
    member_entity_ids="<ENTITY_ID>" # <- aus 7. 
```

Mehrere User kommasepariert: `member_entity_ids="id1,id2,id3"`

## 10. Login testen

```bash
bao login -method=userpass username=jochen
```

 * Password aus 4. verwenden 


## 11. Rechte prüfen

```bash
# "test" wäre ein beliebiges Secret, was ich anlegen wollen würde 
bao token capabilities secret/data/test
bao read identity/group/name/admins
```

## Optional: Darf ich Passwörter ändern ? 

```
bao token capabilities auth/userpass/users/*/password
```

  * So ändere ich meine eigenes Passwort

```
bao write auth/userpass/users/jochen/password password="neuesPasswort"
```

  * So teste ich, ob es funktioniert

```
bao write auth/userpass/users/jochen/password password="neuesPasswort"
```


### Step 1: token revoken und als root anmelden 

```
# root-token eingeben 
bao login
```

```
cd
mkdir -p openbao-hcl
cd openbao-hcl
nano password-change.hcl
```

```bash
bao auth list
```

```hcl
# password-change.hcl
path "auth/userpass/users/{{identity.entity.aliases.<USERPASS_ACCESSOR>.name}}/password" {
  capabilities = ["update"]
}
```

```bash
bao policy write password-change password-change.hcl
```

```
# in admins gruppe aufnehmen
# Schritt 1  - auslesen
bao read -format=json identity/group/name/admins
# Schritt 2 - Neue Gruppe ergänzen
# Es wird nur das genommen, was hier steht, alles andere wird überschrieben
bao write identity/group \
    name="admins" \
    policies="admin-policy,password-change"
```



