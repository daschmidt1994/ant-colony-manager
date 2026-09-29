# Backup außer Haus (WebDAV)

Die nächtlichen Backups ([09-backup-restore.md](09-backup-restore.md)) liegen auf demselben Server wie die Daten. Fällt die Platte aus oder wird der Server gestohlen, sind beide weg. Deshalb kann der Server jedes neue Backup zusätzlich in einen **WebDAV-Ordner** kopieren – Nextcloud, ownCloud, NAS (Synology, QNAP, Unraid mit WebDAV-Container), Hetzner Storage Box u. a.

## Einrichten (Admin)

App/Web → **Mehr → Server-Verwaltung → Backup außer Haus**:

| Feld | Beispiel |
|---|---|
| WebDAV-Adresse (Ordner) | Nextcloud: `https://cloud.example.com/remote.php/dav/files/NAME/acm-backups` (Dateien → Einstellungen unten links → WebDAV, dahinter ein Ordnername) · Storage Box: `https://u12345.your-storagebox.de/acm-backups` |
| Benutzer / Passwort | Nextcloud: **App-Passwort** (Einstellungen → Sicherheit → „Neues App-Passwort“) |
| Backups dort behalten | Standard 7; ältere werden dort gelöscht |

„Verbindung testen“ prüft Adresse und Anmeldung und legt den Ordner an. „Jetzt hochladen“ überträgt sofort das neueste Backup. Mit dem Schalter „Automatisch …“ prüft der Server alle 10 Minuten, ob ein neues Backup fertig ist, und lädt es hoch. Status und letzter Fehler stehen oben auf der Seite.

Das Passwort wird verschlüsselt gespeichert (Schlüssel aus `INSTANCE_SECRET`, wie beim E-Mail-Server) und nie angezeigt. Der Backup-Ordner ist im App-Container bereits schreibgeschützt eingebunden (`/data/backups`) – an der `compose.yml` muss nichts geändert werden.

## Was liegt dort?

```
acm-backups/
  2026-09-28T0300/  db.dump  manifest.json  uploads.sha256  env.redacted  OK
  2026-09-29T0300/  …
  uploads/          alle Fotos (gemeinsam für alle Backups)
```

- **Fotos werden nur einmal übertragen**, danach nur neue oder geänderte – die erste Übertragung dauert, die nächtlichen danach sind klein.
- **OK** kommt zuletzt: Ein Backup-Ordner ohne `OK` ist unvollständig (Abbruch).
- Die **unverschlüsselte Konfiguration** (`env` bei `BACKUP_INCLUDE_ENV=true`, mit Passwörtern) wird **nie** hochgeladen – nur `env.redacted`.
- Im Ordner `uploads/` wird nichts gelöscht; auch Fotos, die du in der App gelöscht hast, bleiben dort (so passen sie auch zu älteren Backups).

## Wiederherstellen

1. Auf dem (neuen) Server den Stack wie gewohnt installieren.
2. Den gewünschten Backup-Ordner herunterladen nach `data/backups/<name>/` und den Ordner `uploads/` nach `data/backups/<name>/uploads/` (Nextcloud-Web: Ordner als ZIP herunterladen; oder `rclone copy`).
3. `./scripts/restore.sh data/backups/<name>` – prüft die Prüfsummen und spielt Datenbank und Fotos ein ([09-backup-restore.md](09-backup-restore.md)).
