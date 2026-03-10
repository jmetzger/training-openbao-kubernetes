# Admin-Nutzer anlegen (zugehörig zur Gruppe admin, mit admin-Rechten) 

# OpenBao Userpass Setup mit Gruppenbasierter Rechtevergabe

## 1. Userpass Auth-Methode aktivieren

```bash
sudo bao auth enable userpass
```

## 2. Prüfen ob gemountet

```bash
sudo bao auth list
```

Erwartete Ausgabe: `userpass/` mit Typ `userpass`.

## 3. Admin-Policy erstellen

```hcl
# admin-policy.hcl
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/health" {
  capabilities = ["read", "sudo"]
}

path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
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
    member_entity_ids="<ENTITY_ID>"
```

Mehrere User kommasepariert: `member_entity_ids="id1,id2,id3"`

## 10. Login testen

```bash
bao login -method=userpass \
    username=jochen \
    password="$TEMP_PW"
```

## 11. Rechte prüfen

```bash
bao token capabilities secret/data/test
bao read identity/group/name/admins
```

## Optional: Self-Service Passwortwechsel erlauben

Policy für den User, um das eigene Passwort zu ändern:

```
cd
mkdir -p openbao-hcl
cd openbao-hcl
nano password-change.hcl
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

Dann entweder dem User direkt zuweisen oder eine zweite Gruppe dafür erstellen.

## Nach der Admin-Arbeit: Token revoken

```bash
bao token revoke -self
unset BAO_TOKEN
```
