# Secret Engines 

## Was sind Pfade ? 

Die Pfade existieren nur **innerhalb von OpenBao** – es ist ein virtueller API-Baum, kein echtes Dateisystem auf der Festplatte.

Jeder Zugriff auf OpenBao geht über die HTTP-API, und der Pfad ist einfach der URL-Teil nach `/v1/`:

```
GET https://bao-server:8200/v1/mydb/creds/readonly
                                 ^^^^^^^^^^^^^^^^^^^^^^
                                 Das ist der Pfad
```

Oder via CLI:

```
bao read mydb/creds/readonly
```

OpenBao schaut sich den ersten Teil des Pfads an (`mydb/`), leitet die Anfrage an die dort gemountete Engine weiter, und die Engine verarbeitet den Rest (`creds/readonly`).

Es ist im Grunde ein **interner Router**: Pfad → Engine → Antwort.



## Was sind secret engines 

