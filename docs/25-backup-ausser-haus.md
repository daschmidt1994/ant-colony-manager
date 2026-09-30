# Backup außer Haus (WebDAV, SMB, NFS)

Die nächtlichen Backups ([09-backup-restore.md](09-backup-restore.md)) liegen auf demselben Server wie die Daten. Fällt die Platte aus oder wird der Server gestohlen, sind beide weg. Deshalb kann der Server jedes neue Backup zusätzlich an einen anderen Ort kopieren:

| Ziel | Wofür |
|---|---|
| **WebDAV** | Nextcloud, ownCloud, Hetzner Storage Box, NAS mit WebDAV |
| **SMB** | Windows-Freigabe, Synology, QNAP, Unraid, Samba – direkt aus der App, ohne Änderung an Docker |
| **NFS / Ordner** | NFS-Freigabe eines NAS, USB-Platte, beliebiger Mount – Docker bindet ihn als Ordner in den Container ein |

## Einrichten (Admin)

App/Web → **Mehr → Server-Verwaltung → Backup außer Haus**, oben das Ziel wählen:

| Feld | Beispiel |
|---|---|
| **WebDAV:** Adresse (Ordner) | Nextcloud: `https://cloud.example.com/remote.php/dav/files/NAME/acm-backups` (Dateien → Einstellungen unten links → WebDAV, dahinter ein Ordnername) · Storage Box: `https://u12345.your-storagebox.de/acm-backups` |
| **SMB:** Freigabe (Ordner) | `smb://nas/backup/acm` = Server `nas`, Freigabe `backup`, Ordner `acm` (wird angelegt). Anderer Port: `smb://nas:1445/backup` |
| **NFS / Ordner:** Ordner im Container | `/offsite` – siehe [NFS einbinden](#nfs-einbinden) |
| Benutzer / Passwort | Nextcloud: **App-Passwort** (Einstellungen → Sicherheit → „Neues App-Passwort“) · SMB: Benutzer des NAS, bei Windows-Domänen `DOMÄNE\name` · NFS: keine |
| Backups dort behalten | Standard 7; ältere werden dort gelöscht |

„Verbindung testen“ prüft Adresse, Anmeldung und Schreibrecht und legt den Ordner an (bei NFS / Ordner muss er schon existieren – ein fehlender Mount soll nicht unbemerkt den Container füllen). „Jetzt hochladen“ überträgt sofort das neueste Backup. Mit dem Schalter „Automatisch …“ prüft der Server alle 10 Minuten, ob ein neues Backup fertig ist, und lädt es hoch. Status und letzter Fehler stehen oben auf der Seite.

Das Passwort wird verschlüsselt gespeichert (Schlüssel aus `INSTANCE_SECRET`, wie beim E-Mail-Server) und nie angezeigt. Der Backup-Ordner ist im App-Container bereits schreibgeschützt eingebunden (`/data/backups`) – an der `compose.yml` muss nichts geändert werden.

### SMB

Unterstützt werden SMB 2 und 3 mit Benutzer und Passwort (NTLM) – das, was Windows und jedes aktuelle NAS anbieten. Am besten einen eigenen Benutzer anlegen, der nur auf die Backup-Freigabe schreiben darf. Der ACM-Server muss das NAS über Port 445 erreichen.

### NFS einbinden

NFS bindet nicht die App ein, sondern Docker: Der App-Container läuft bewusst ohne Root-Rechte, und die meisten NAS nehmen NFS nur von Root (privilegierter Port) an. Docker kann NFS-Freigaben selbst als Volume einhängen.

1. Am NAS eine NFS-Freigabe anlegen und dem Docker-Host Schreibrecht geben. Geschrieben wird mit `PUID`/`PGID` aus der `.env` (Standard 1000:1000) – entweder diese Benutzer-ID auf der Freigabe erlauben oder am NAS alle Zugriffe auf einen Benutzer abbilden (Synology: „Alle Benutzer zu admin zuordnen“ bzw. Squash; Unraid: Security „Public“ oder Rule `*(rw,all_squash,anonuid=1000,anongid=1000)`).
2. Neben der `compose.yml` eine Datei **`compose.override.yml`** anlegen (Docker Compose liest sie automatisch; Updates überschreiben sie nicht):

   ```yaml
   services:
     app:
       volumes:
         - offsite:/offsite
   volumes:
     offsite:
       driver: local
       driver_opts:
         type: nfs
         o: "addr=192.168.178.10,rw,nfsvers=4"
         device: ":/volume1/acm-backup"
   ```

   `addr` = Adresse des NAS, `device` = exportierter Pfad (Synology: `/volume1/<Freigabe>`, Unraid: `/mnt/user/<Freigabe>`). NFS v3: `nfsvers=3`.
3. `docker compose up -d` – danach in der App **NFS / Ordner** wählen, Ordner `/offsite`, „Verbindung testen“.

Dasselbe geht mit einer USB-Platte oder einem schon am Host gemounteten Ordner: `- /mnt/usb/acm:/offsite` unter `volumes` des Dienstes `app`. Der lokale Backup-Ordner (`/data/backups`) und die Fotos (`/data/uploads`) werden als Ziel abgelehnt – sonst würde „Backups dort behalten“ die lokalen Backups löschen.

Bei Unraid mit Dockhand oder Portainer: dieselben Zeilen im Stack-Editor ergänzen ([17-unraid-dockhand.md](17-unraid-dockhand.md)).

## Was liegt dort?

```
acm-backups/
  2026-09-28T0300/  db.dump  manifest.json  uploads.sha256  env.redacted  OK
  2026-09-29T0300/  …
  uploads/          alle Fotos (gemeinsam für alle Backups)
```

- **Fotos werden nur einmal übertragen**, danach nur neue oder geänderte – die erste Übertragung dauert, die nächtlichen danach sind klein.
- **OK** kommt zuletzt: Ein Backup-Ordner ohne `OK` ist unvollständig (Abbruch). Bei SMB und NFS wird jede Datei erst als `….part` geschrieben und dann umbenannt.
- Die **unverschlüsselte Konfiguration** (`env` bei `BACKUP_INCLUDE_ENV=true`, mit Passwörtern) wird **nie** hochgeladen – nur `env.redacted`.
- Im Ordner `uploads/` wird nichts gelöscht; auch Fotos, die du in der App gelöscht hast, bleiben dort (so passen sie auch zu älteren Backups).

## Wiederherstellen

1. Auf dem (neuen) Server den Stack wie gewohnt installieren.
2. Den gewünschten Backup-Ordner nach `data/backups/<name>/` kopieren und den Ordner `uploads/` nach `data/backups/<name>/uploads/` (Nextcloud-Web: Ordner als ZIP herunterladen; SMB/NFS: einfach kopieren; oder `rclone copy`).
3. `./scripts/restore.sh data/backups/<name>` – prüft die Prüfsummen und spielt Datenbank und Fotos ein ([09-backup-restore.md](09-backup-restore.md)).
